#!/usr/bin/env bash
# followup-nodest-failure (W5): a no-destination seat-bell failure in followup-deliver.sh is never silent. When seat-event.sh fails, ONE durable
# {"nodest_failure":true,key} record (key nodest|id|rev|sha1(fp)|bell) and ONE canonical wm-asks row (owner ctl, due +60 min, grep check on the settle marker, marker nodestfail:<hash>)
# exist across any number of replays; the entry stays delivered:false (retry allowed); a later successful bell delivers it once and writes ONE {"nodest_settled":true,key} marker.
# Scratch dirs and stubs only (SEAT_EVENT_BIN, WM_ASKS_BIN); NODEST_DEL overrides the script under test (RED run against the installed bytes).
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
base="$(mktemp -d "${TMPDIR:-/tmp}/followup-nodest.XXXXXX")"; trap 'rm -rf "$base"' EXIT
fail=0; pass=0
chk() { if [ "$2" = 0 ]; then echo "PASS $1"; pass=$((pass + 1)); else echo "FAIL $1"; fail=$((fail + 1)); fi; }
DEL="${NODEST_DEL:-$here/.local/bin/followup-deliver.sh}"; EV="$here/.local/bin/followup-eval.py"
export HOME="$base/home" FOLLOWUP_STATE_DIR="$base/state" FOLLOWUP_OUTBOX="$base/state/outbox.jsonl" FOLLOWUP_DELIVER_CMD="$DEL"
export SEAT_EVENT_BIN="$base/seat-event" WM_ASKS_BIN="$base/wm-asks" ASKS="$base/asks.jsonl" BELLS="$base/bells.log" BELL_RC="$base/bell_rc"
mkdir -p "$HOME" "$FOLLOWUP_STATE_DIR"; : >"$ASKS"; : >"$BELLS"
printf '#!/usr/bin/env bash\necho "$*" >>"$BELLS"; exit "$(cat "$BELL_RC")"\n' >"$SEAT_EVENT_BIN"
cat >"$WM_ASKS_BIN" <<'STUB'
#!/usr/bin/env bash
[ "$1" = asks ] || exit 2; shift; sub="$1"; shift
if [ "$sub" = query ]; then
  txt=""; while [ $# -gt 0 ]; do [ "$1" = --text ] && txt="$2"; shift; done
  jq -s --arg t "$txt" '[.[] | select(.what | contains($t))]' "$ASKS"
else
  o=""; d=""; c=""; w=""; while [ $# -gt 0 ]; do case "$1" in --owner) o="$2";; --due) d="$2";; --check) c="$2";; --what) w="$2";; esac; shift; done
  jq -nc --arg o "$o" --arg d "$d" --arg c "$c" --arg w "$w" '{ask_id:"A-stub",owner:$o,due:$d,check:$c,what:$w}' >>"$ASKS"; echo A-stub
fi
STUB
chmod +x "$SEAT_EVENT_BIN" "$WM_ASKS_BIN"
echo 9 >"$BELL_RC"
entry="$(jq -nc '{id:"E1",rev:2,kind:"correction-owed",seat:"ctl",fp:"fp-one",detail:"x",ts:"2026-11-09T10:00:00",delivered:false}')"
other="$(jq -nc '{id:"E2",rev:1,kind:"correction-owed",seat:"ctl",fp:"fp-two",detail:"y",ts:"2026-11-09T10:00:01",delivered:false}')"
printf '%s\n' "$entry" >"$FOLLOWUP_OUTBOX"
nf() { jq -s '[.[] | select(.nodest_failure==true)] | length' "$FOLLOWUP_OUTBOX"; }
for i in 1 2 3; do python3 -I "$EV" replay; done
[ "$(nf)" = 1 ]; st=$?; chk "1: failure record present exactly once across 3 replays (got $(nf))" "$st"
[ "$(jq -s '[.[]|select(.nodest_failure==true)][0]|.key' "$FOLLOWUP_OUTBOX" 2>/dev/null)" = '"nodest|E1|2|'"$(printf 'fp-one' | sha1sum | cut -c1-12)"'|bell"' ]; chk "1b: failure identity = nodest|id|rev|sha1(fp)|bell" $?
[ "$(grep -c . "$ASKS")" = 1 ]; st=$?; chk "2: owned row opened exactly once across 3 replays (got $(grep -c . "$ASKS"))" "$st"
r="$(jq -sc '.[0]' "$ASKS")"
[ "$(jq -r .owner <<<"$r")" = ctl ] && grep -q 'nodestfail:' <<<"$r" && grep -q 'nodest_settled' <<<"$r" && [ "$(jq -r .due <<<"$r")" = "$(date -d '+60 minutes' +%Y-%m-%dT%H:%M)" ]; chk "2b: row owner ctl, due +60 min, marker + settle check present" $?
[ "$(jq -s '[.[]|select(.id=="E1" and .delivered==false)]|length' "$FOLLOWUP_OUTBOX")" = 1 ] && [ "$(grep -c . "$BELLS")" = 3 ]; chk "3: entry stays undelivered and the retry still rang the bell each replay" $?
printf '%s\n' "$other" >>"$FOLLOWUP_OUTBOX"; python3 -I "$EV" replay
[ "$(nf)" = 2 ] && [ "$(grep -c . "$ASKS")" = 2 ]; st=$?; chk "4: a distinct entry gets its own record and row (records $(nf), rows $(grep -c . "$ASKS"))" "$st"
echo 0 >"$BELL_RC"; python3 -I "$EV" replay; python3 -I "$EV" replay
[ "$(jq -s '[.[]|select(.id=="E1" and .delivered==true)]|length' "$FOLLOWUP_OUTBOX")" = 1 ] && [ "$(jq -s '[.[]|select(.id=="E2" and .delivered==true)]|length' "$FOLLOWUP_OUTBOX")" = 1 ]; chk "5: recovery delivers each entry" $?
[ "$(jq -s '[.[]|select(.nodest_settled==true)]|length' "$FOLLOWUP_OUTBOX")" = 2 ] && [ "$(grep -c . "$BELLS")" = 7 ]; st=$?; chk "5b: one settle marker per entry; no bell after delivery (bells $(grep -c . "$BELLS"))" "$st"
k="$(jq -sr '[.[]|select(.nodest_failure==true)][0].key' "$FOLLOWUP_OUTBOX")"; chk="$(jq -sr '.[0].check' "$ASKS")"
bash -c "$chk"; chk "5c: the row's check command passes once settled" $?
# a clean no-dest bell with no prior failure writes nothing to the outbox
b4="$(cksum <"$FOLLOWUP_OUTBOX")"; jq -nc '{id:"E3",rev:1,kind:"x",seat:"ctl",fp:"f",detail:"z"}' | "$DEL"; rc=$?
[ "$rc" = 0 ] && [ "$(cksum <"$FOLLOWUP_OUTBOX")" = "$b4" ]; chk "6: a clean bell touches nothing and exits 0" $?
# dest path unchanged: no hermes on PATH -> exit 1, no nodest records for it
n0="$(nf)"; jq -nc '{id:"D1",dest:"discord:#ops",summary:"s",task:"T",rev:1,result:"r",kind:"result"}' | PATH=/usr/bin:/bin "$DEL" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$(nf)" = "$n0" ]; chk "7: dest path without hermes still exits 1 and writes no nodest record" $?
# wm-asks outage (query or add fails persistently): the failure is loud, ONE dedupe-keyed nodest_unowned marker exists per key, followup-eval surfaces it
# as a nodest-unowned disposition, and recovery creates exactly ONE row and clears the marker.
OUT="$base/out"; mkdir -p "$OUT"
export FOLLOWUP_OUTBOX="$OUT/outbox.jsonl" FOLLOWUP_STATE_DIR="$OUT/state" NODEST_UNOWNED_MIN=0 ASKS="$OUT/asks.jsonl"; mkdir -p "$FOLLOWUP_STATE_DIR"; : >"$ASKS"
printf '%s\n' "$(jq -nc '{id:"O1",rev:1,kind:"correction-owed",seat:"ctl",fp:"fp-out",detail:"o",ts:"2026-11-09T10:00:00",delivered:false}')" >"$FOLLOWUP_OUTBOX"
echo 9 >"$BELL_RC"; export WM_ASKS_BIN="$OUT/wm-asks-down"; printf '#!/usr/bin/env bash\nexit 1\n' >"$WM_ASKS_BIN"; chmod +x "$WM_ASKS_BIN"
for i in 1 2 3; do python3 -I "$EV" replay >/dev/null 2>&1; done
uc() { jq -s '[.[] | select(.nodest_unowned==true)] | length' "$FOLLOWUP_OUTBOX"; }
[ "$(uc)" = 1 ] && [ "$(grep -c 'for O1;' "$ASKS")" = 0 ] && [ "$(nf)" = 1 ]; st=$?; chk "8: outage leaves ONE nodest_unowned marker (got $(uc)) and one failure record, no row" "$st"
jq -s -e '[.[]|select(.nodest_unowned==true)][0] | (.key|startswith("nodest|O1|1|")) and .id=="O1"' "$FOLLOWUP_OUTBOX" >/dev/null; chk "8b: marker names id and the failure key" $?
echo "$(jq -nc '{id:"O1",rev:1,kind:"correction-owed",seat:"ctl",fp:"fp-out",detail:"o"}')" | env -u FOLLOWUP_LOCK_HELD WM_ASKS_BIN="$OUT/wm-asks-down" "$DEL" >/dev/null 2>"$OUT/err"; grep -q 'O1' "$OUT/err" && grep -q 'rev=1' "$OUT/err" && grep -q 'nodest|O1|1|' "$OUT/err"; chk "8c: each failed row creation prints a loud stderr line naming id/rev/key" $?
python3 -I "$EV" eval --seat ctl | jq -e '[.dispositions[] | select(.kind=="nodest-unowned" and .id=="O1")] | length == 1' >/dev/null; chk "8d: followup-eval surfaces the unowned record as a nodest-unowned disposition" $?
python3 -I "$EV" new --seat ctl >/dev/null 2>&1; python3 -I "$EV" new --seat ctl >/dev/null 2>&1
[ "$(uc)" = 1 ]; st=$?; chk "8e: repeated eval/new/replay never grow the marker (got $(uc))" "$st"
export WM_ASKS_BIN="$base/wm-asks"; python3 -I "$EV" replay >/dev/null 2>&1; python3 -I "$EV" replay >/dev/null 2>&1
o1rows() { grep -c 'for O1;' "$ASKS"; }
[ "$(o1rows)" = 1 ] && [ "$(jq -s '[.[]|select(.nodest_failure==true and .id=="O1")]|length' "$FOLLOWUP_OUTBOX")" = 1 ]; st=$?; chk "9: wm-asks recovery creates exactly ONE row for O1 (rows $(o1rows))" "$st"
python3 -I "$EV" eval --seat ctl | jq -e '[.dispositions[] | select(.kind=="nodest-unowned")] | length == 0' >/dev/null; chk "9b: the disposition clears once the row exists" $?
echo "followup-nodest-failure: $pass pass, $fail fail"; [ "$fail" = 0 ]
