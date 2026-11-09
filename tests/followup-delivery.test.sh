#!/usr/bin/env bash
# followup-delivery (ledger ask A1346 amendment, notification dedupe): followup-deliver.sh sends an outbox event to a destination through `hermes send`
# exactly once per (dest, task, rev, result, kind) and per part (summary, attachment), records each returned message id in the existing outbox,
# retries a provider 429 on the attachment with backoff, then falls back to chunked text, and never reports delivered until a send succeeded.
# Fixtures only: a fake hermes CLI and a fake sleep on PATH; no network, no real outbox.
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
base="$(mktemp -d "${TMPDIR:-/tmp}/followup-delivery.XXXXXX")"; trap 'rm -rf "$base"' EXIT
fail=0; pass=0
chk() { if [ "$2" = 0 ]; then echo "PASS $1"; pass=$((pass + 1)); else echo "FAIL $1"; fail=$((fail + 1)); fi; }
DEL="$here/.local/bin/followup-deliver.sh"; EV="$here/.local/bin/followup-eval.py"
mkdir -p "$base/bin" "$base/state"
cat >"$base/bin/hermes" <<'FAKE'
#!/usr/bin/env bash
# fake `hermes send --to T [--json] BODY`; logs "T<TAB>BODY"; FH_ATTACH_429=N fails the next N MEDIA: sends (always = every one), FH_TEXT_429=always fails every text send, =afterN fails chunk sends once N chunks went out, FH_RETRY_AFTER sets the 429 retry_after, =chunks fails every text send except the summary
[ "${1:-}" = send ] || exit 2; shift
to=""; body=""
while [ $# -gt 0 ]; do case "$1" in --to|-t) to="$2"; shift 2;; --json|-q) shift;; *) body="$1"; shift;; esac; done
printf '%s\t%s\n' "$to" "$body" >>"$FH_LOG"
n=0; [ -f "$FH_CTR" ] && n="$(cat "$FH_CTR")"
fail429() { echo "{\"success\":false,\"error\":\"Discord 429 rate limited\",\"retry_after\":${FH_RA_RAW:-${FH_RETRY_AFTER:-2}}}"; exit 1; }
# FH_DIE holds summary|media|chunk: the next send of that kind is logged, then the calling followup-deliver.sh is SIGKILLed (the hit happened, the local record did not), one shot
if [ -f "$FH_DIE" ]; then k=chunk; case "$body" in MEDIA:*) k=media;; "analysis done") k=summary;; esac
  if [ "$(cat "$FH_DIE")" = "$k" ]; then rm -f "$FH_DIE"; p=$PPID
    t=""; while [ "$p" -gt 1 ]; do tr '\0' '\n' </proc/$p/cmdline | sed -n 2p | grep -q 'followup-deliver\.sh$' && t=$p; p="$(awk '/^PPid/{print $2}' /proc/$p/status)"; done
    [ -n "$t" ] && kill -9 "$t"   # the outermost match is the script itself, not its command-substitution subshell
    exit 1; fi; fi
case "$body" in
  MEDIA:*) c="$(cat "$FH_ATTACH_429" 2>/dev/null || echo 0)"
           if [ "$c" = always ]; then fail429; elif [ "$c" -gt 0 ] 2>/dev/null; then echo $((c - 1)) >"$FH_ATTACH_429"; fail429; fi;;
  *) m="$(cat "$FH_TEXT_429" 2>/dev/null)"
     case "$m" in after*) [ "$body" != "analysis done" ] && [ $((n - 1)) -ge "${m#after}" ] && fail429;; esac
     { [ "$m" = always ] || { [ "$m" = chunks ] && [ "$body" != "analysis done" ]; }; } && fail429;;
esac
n=$((n + 1)); echo "$n" >"$FH_CTR"; echo "{\"success\":true,\"message_id\":\"m$n\"}"
FAKE
printf '#!/usr/bin/env bash\necho "$1" >>"$FS_LOG"\n' >"$base/bin/sleep"
chmod +x "$base/bin/hermes" "$base/bin/sleep"
export PATH="$base/bin:$PATH" HOME="$base/home" FH_LOG="$base/h.log" FH_CTR="$base/h.ctr" FH_ATTACH_429="$base/a429" FH_DIE="$base/die" FH_TEXT_429="$base/t429" FS_LOG="$base/s.log"
export FOLLOWUP_STATE_DIR="$base/state" FOLLOWUP_OUTBOX="$base/state/outbox.jsonl" FOLLOWUP_DELIVER_RETRIES=3
mkdir -p "$HOME"; : >"$FOLLOWUP_OUTBOX"
head -c 4000 /dev/zero | tr '\0' 'x' >"$base/report.txt"
ev() { # ev result [task] -> one outbox event (the shape of a result event with a destination)
  jq -nc --arg r "$1" --arg t "${2:-T1}" --arg a "$base/report.txt" \
    '{id:("ev-"+$t+"-"+$r),seat:"ctl",kind:"result",dest:"discord:#ops",task:$t,rev:1,result:$r,summary:"analysis done",attachment:$a,delivered:false}'; }
reset() { : >"$FH_LOG"; : >"$FS_LOG"; rm -f "$FH_CTR" "$FH_ATTACH_429" "$FH_TEXT_429" "$FH_DIE"; : >"$base/bell"; : >"$FOLLOWUP_OUTBOX"; }
sends() { grep -c . "$FH_LOG"; }
attach_sends() { grep -c $'\tMEDIA:' "$FH_LOG"; }

# (a) the same outbox event delivered twice yields one send per part
reset; e="$(ev R1)"
"$DEL" <<<"$e"; rc1=$?; n1="$(sends)"; "$DEL" <<<"$e"; rc2=$?
[ "$rc1" = 0 ] && [ "$rc2" = 0 ] && [ "$n1" = 2 ] && [ "$(sends)" = 2 ]; st=$?; chk "a: same event twice = one summary + one attachment send, both runs exit 0 (rc $rc1/$rc2, sends $n1 then $(sends))" "$st"
reset; e1="$(ev R1)"; e2="$(ev R1 | jq -c '.id="ev-other-source"')"
"$DEL" <<<"$e1"; "$DEL" <<<"$e2"
[ "$(sends)" = 2 ]; st=$?; chk "a: two outbox lines with one result identity (different ids) still send once" "$st"
reset; "$DEL" <<<"$(ev R1)"; "$DEL" <<<"$(ev R2)"
[ "$(sends)" = 4 ]; st=$?; chk "a: a new result identity is a new delivery (changed result is visible)" "$st"
reset; for i in 1 2 3 4; do "$DEL" <<<"$(ev R1)" >/dev/null 2>&1 & done; wait
[ "$(sends)" = 2 ]; st=$?; chk "a: four concurrent senders of one event give one summary + one attachment (sends $(sends))" "$st"
# a replay over two identical queued lines sends once
reset; { ev R1; ev R1; } >"$FOLLOWUP_OUTBOX"
python3 -I "$EV" replay >/dev/null 2>&1
[ "$(sends)" = 2 ]; st=$?; chk "a: replay of two identical queued events sends once (sends $(sends))" "$st"

# (b) Discord 429 on the attachment: backoff retries, then chunked text; the summary is never reposted; not delivered until a send succeeds
reset; echo always >"$FH_ATTACH_429"; e="$(ev R1)"
"$DEL" <<<"$e"; rc=$?
[ "$(attach_sends)" = 3 ]; st=$?; chk "b: attachment is attempted FOLLOWUP_DELIVER_RETRIES (3) times (got $(attach_sends))" "$st"
[ "$(grep -c . "$FS_LOG")" = 2 ] && [ "$(sed -n 1p "$FS_LOG")" -ge 2 ] && [ "$(sed -n 2p "$FS_LOG")" -gt "$(sed -n 1p "$FS_LOG")" ]; src=$?; chk "b: backoff sleeps between attempts, at least Retry-After and growing ($(paste -sd, "$FS_LOG"))" $src
chunks="$(grep -v $'\tMEDIA:' "$FH_LOG" | grep -vc 'analysis done')"
[ "$chunks" -ge 2 ] && [ "$rc" = 0 ]; st=$?; chk "b: then falls back to chunked text sends and exits 0 (chunks $chunks, rc $rc)" "$st"
[ "$(grep -c 'analysis done' "$FH_LOG")" = 1 ]; st=$?; chk "b: the summary was sent once, not per attempt" "$st"
# summary succeeds, then attachment AND chunks fail: the item stays undelivered, owned and retryable, and the summary is not reposted on retry
reset; echo always >"$FH_ATTACH_429"; echo chunks >"$FH_TEXT_429"; ev R1 >"$FOLLOWUP_OUTBOX"
python3 -I "$EV" replay >/dev/null 2>&1
grep -q '"delivered":false' "$FOLLOWUP_OUTBOX"; st=$?; chk "b: attachment and fallback both failing leave the outbox item delivered:false" "$st"
[ "$(grep -c 'analysis done' "$FH_LOG")" = 1 ]; st=$?; chk "b: the summary part that did succeed is on record" "$st"
rm -f "$FH_ATTACH_429" "$FH_TEXT_429"
python3 -I "$EV" replay >/dev/null 2>&1
! grep -q '"delivered":false' "$FOLLOWUP_OUTBOX"; st=$?; chk "b: once the provider recovers, replay delivers the item" "$st"
[ "$(grep -c 'analysis done' "$FH_LOG")" = 1 ] && [ "$(attach_sends)" -ge 1 ]; st=$?; chk "b: recovery sent the attachment and did not repost the summary" "$st"

# (c) a successful send is recorded once, with its message id
reset; "$DEL" <<<"$(ev R1)"
jq -e -s '[.[]|select(.sent_part==true)] | length==2 and (map(.message_id)|sort==["m1","m2"]) and all(.[]; .key=="discord:#ops|T1|1|R1|result")' "$FOLLOWUP_OUTBOX" >/dev/null; st=$?; chk "c: outbox holds one sent-part record per part with its message id and the dedupe key" "$st"
"$DEL" <<<"$(ev R1)"
[ "$(jq -s '[.[]|select(.sent_part==true)]|length' "$FOLLOWUP_OUTBOX")" = 2 ]; st=$?; chk "c: a repeat adds no second record" "$st"
# an entry without a destination keeps the seat-bell path (existing contract)
reset; printf '#!/usr/bin/env bash\necho bell >>"$FH_LOG"\n' >"$base/bin/seat-event.sh"; chmod +x "$base/bin/seat-event.sh"
SEAT_EVENT_BIN="$base/bin/seat-event.sh" "$DEL" <<<'{"id":"x1","seat":"ctl","kind":"obligation","detail":"d"}'; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$FH_LOG")" = bell ]; st=$?; chk "c: an event with no destination still rings the seat bell" "$st"
# (d) real-adapter paths through followup-eval.py replay -> followup-deliver.sh -> spy hermes
# one transient attachment 429: the retry sends the file itself, no chunk text, summary once
reset; echo 1 >"$FH_ATTACH_429"; ev R1 >"$FOLLOWUP_OUTBOX"
python3 -I "$EV" replay >/dev/null 2>&1
[ "$(attach_sends)" = 2 ] && [ "$(grep -v $'\tMEDIA:' "$FH_LOG" | grep -vc 'analysis done')" = 0 ] && [ "$(grep -c 'analysis done' "$FH_LOG")" = 1 ] && ! grep -q '"delivered":false' "$FOLLOWUP_OUTBOX"
st=$?; chk "d: replay with one attachment 429 retries the file (2 MEDIA sends), no chunks, summary once, item delivered (media $(attach_sends))" "$st"
# Retry-After longer than the backoff is honored
reset; echo 1 >"$FH_ATTACH_429"; FH_RETRY_AFTER=30 "$DEL" <<<"$(ev R1)"
[ "$(sed -n 1p "$FS_LOG")" = 30 ]; src=$?; chk "d: a Retry-After of 30 s sleeps 30 s, not the shorter backoff ($(paste -sd, "$FS_LOG"))" $src
# chunk fallback interrupted midway: the retry resumes after the last sent chunk, never re-sends the file or earlier chunks
reset; echo always >"$FH_ATTACH_429"; echo after1 >"$FH_TEXT_429"; ev R1 >"$FOLLOWUP_OUTBOX"
python3 -I "$EV" replay >/dev/null 2>&1
grep -q '"delivered":false' "$FOLLOWUP_OUTBOX" && [ "$(jq -s '[.[]|select(.sent_part==true and (.part|startswith("attachment-chunk-")))]|length' "$FOLLOWUP_OUTBOX")" = 1 ]; st=$?; chk "d: a failure after chunk 1 leaves delivered:false with exactly one chunk on record" "$st"
rm -f "$FH_TEXT_429"; : >"$FH_LOG"
python3 -I "$EV" replay >/dev/null 2>&1
! grep -q '"delivered":false' "$FOLLOWUP_OUTBOX" && [ "$(attach_sends)" = 0 ] && ! grep -q 'analysis done' "$FH_LOG" && [ "$(grep -c . "$FH_LOG")" = 2 ]; st=$?; chk "d: resume sends no MEDIA, no summary, only chunks 2 and 3 (sends $(sends))" "$st"
[ "$(jq -s '[.[]|select(.sent_part==true and (.part|startswith("attachment-chunk-")))]|length' "$FOLLOWUP_OUTBOX")" = 3 ]; st=$?; chk "d: all three chunks are on record exactly once" "$st"
# (e) crash after the remote send, before the local record: the part is UNKNOWN on replay, never blindly resent
bells() { grep -c . "$base/bell"; }
printf '#!/usr/bin/env bash\necho "$2" >>"%s/bell"\n' "$base" >"$base/bin/seat-event.sh"; chmod +x "$base/bin/seat-event.sh"
export SEAT_EVENT_BIN="$base/bin/seat-event.sh"
for kind in summary media chunk; do
  reset; ev R1 >"$FOLLOWUP_OUTBOX"; [ "$kind" = chunk ] && echo always >"$FH_ATTACH_429"; echo "$kind" >"$FH_DIE"
  python3 -I "$EV" replay >/dev/null 2>&1; hits1="$(sends)"; : >"$FH_LOG"
  python3 -I "$EV" replay >/dev/null 2>&1
  [ "$(sends)" = 0 ]; st=$?; chk "e/$kind: replay after a crash mid-send sends nothing (no duplicate of the unknown part, later parts held; sends $(sends))" "$st"
  grep -q '"delivered":false' "$FOLLOWUP_OUTBOX"; st=$?; chk "e/$kind: the item stays delivered:false" "$st"
  jq -e -s 'any(.[]; .needs_reconcile==true and (.part|length>0))' "$FOLLOWUP_OUTBOX" >/dev/null; st=$?; chk "e/$kind: a needs_reconcile record names the part ($(jq -rs '[.[]|select(.needs_reconcile==true)|.part]|join(",")' "$FOLLOWUP_OUTBOX"))" "$st"
  [ "$(bells)" = 1 ]; st=$?; chk "e/$kind: the seat bell rang once" "$st"
  python3 -I "$EV" replay >/dev/null 2>&1
  [ "$(sends)" = 0 ] && [ "$(bells)" = 1 ] && [ "$(jq -s '[.[]|select(.needs_reconcile==true)]|length' "$FOLLOWUP_OUTBOX")" = 1 ]; st=$?; chk "e/$kind: a third replay adds no send, no second record, no second bell" "$st"
done
# settled by a human: action=resend lets the part go out again; later parts then follow
reset; ev R1 >"$FOLLOWUP_OUTBOX"; echo summary >"$FH_DIE"; python3 -I "$EV" replay >/dev/null 2>&1; : >"$FH_LOG"
jq -nc '{reconciled:true,key:"discord:#ops|T1|1|R1|result",part:"summary",action:"resend"}' >>"$FOLLOWUP_OUTBOX"
python3 -I "$EV" replay >/dev/null 2>&1
! grep -q '"delivered":false' "$FOLLOWUP_OUTBOX" && [ "$(grep -c 'analysis done' "$FH_LOG")" = 1 ] && [ "$(attach_sends)" = 1 ]; st=$?; chk "e: a reconciled resend record releases the part and the item then delivers" "$st"

# (f) empty attachment file: terminates, delivered, with an explicit note
: >"$base/empty.txt"
reset; echo always >"$FH_ATTACH_429"; ev R1 | jq -c --arg a "$base/empty.txt" '.attachment=$a' >"$FOLLOWUP_OUTBOX"
python3 -I "$EV" replay >/dev/null 2>&1
! grep -q '"delivered":false' "$FOLLOWUP_OUTBOX"; st=$?; chk "f: an empty attachment file marks the item delivered" "$st"
grep -q 'attachment empty' "$FH_LOG" && [ "$(grep -c 'analysis done' "$FH_LOG")" = 1 ]; st=$?; chk "f: the explicit empty-attachment note is sent, the summary once" "$st"
: >"$FH_LOG"; python3 -I "$EV" replay >/dev/null 2>&1
[ "$(sends)" = 0 ]; st=$?; chk "f: a further replay sends nothing" "$st"

# (g) Retry-After is validated before sleep: numeric, clamped, else exponential backoff
ra_sleep() { reset; echo 1 >"$FH_ATTACH_429"; FH_RA_RAW="$1" "$DEL" <<<"$(ev R1)" >/dev/null 2>&1; sed -n 1p "$FS_LOG"; }
for c in '"abc":2' '-5:2' '-5.5:2' '"":2' '"1e9":2' 'null:2' '{"a":1}:2' '99999999999:300' '"99999999999999999999":300' '1000:300' '7:7' '"9":9' '1.9:2'; do
  v="${c%:*}"; want="${c##*:}"; got="$(ra_sleep "$v")"
  [ "$got" = "$want" ]; st=$?; chk "g: retry_after $v sleeps $want s (got '$got')" "$st"
done

# no chk call may take its status from $? after a $(...) in its own message (that status is the substitution's, always 0)
! grep -nE '^[^#]*chk ".*\$\(.*" \$\?$' "$0"; st=$?; chk "meta: no chk call reads \$? after a command substitution in its message" "$st"
echo "followup-delivery: $pass PASS $fail FAIL"; [ "$fail" = 0 ]
