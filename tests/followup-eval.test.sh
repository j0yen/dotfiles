#!/usr/bin/env bash
# followup-eval (ledger ask A1346, repair of A1307): ONE shared evaluator (.local/bin/followup-eval.py) gives every open obligation a disposition
# (verified | claimed | blocked | ready | overdue-ack | stale-worker) and persists ONE fingerprint file that owed-now.sh and seat-followups.sh both read,
# so an unchanged accounted item is cited at most once across both hooks. Fixture state dirs and a fake wm-asks only; no real ledger, no product build.
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
base="$(mktemp -d "${TMPDIR:-/tmp}/followup-eval.XXXXXX")"; trap 'rm -rf "$base"' EXIT
fail=0; pass=0
chk() { if [ "$2" = 0 ]; then echo "PASS $1"; pass=$((pass + 1)); else echo "FAIL $1"; fail=$((fail + 1)); fi; }
EV="$here/.local/bin/followup-eval.py"; OWED="$here/.claude/hooks/owed-now.sh"; SF="$here/.claude/hooks/seat-followups.sh"
[ -f "$EV" ]; chk "0: followup-eval.py exists" $?
cat >"$base/wm-asks" <<'FAKE'
#!/usr/bin/env bash
[ "${1:-}" = query ] || exit 2
[ -n "${FU_ASKS_FAIL:-}" ] && exit "$FU_ASKS_FAIL"
[ -n "${FU_ASKS_GARBAGE:-}" ] && { echo 'not json'; exit 0; }
cat "$FU_ASKS"
FAKE
printf '#!/usr/bin/env bash\n[ -e "$FU_ALIVE_DIR/$1" ]\n' >"$base/alive"
printf '#!/usr/bin/env bash\ncat >>"$FU_DELIVERED"; [ ! -e "$FU_DELIVER_FAIL" ]\n' >"$base/deliver"
chmod +x "$base/wm-asks" "$base/alive" "$base/deliver"
export HOME="$base/home" WM_ASKS_BIN="$base/wm-asks" FU_ASKS="$base/asks.json" FU_ALIVE_DIR="$base/alive.d" FU_DELIVERED="$base/delivered.log" FU_DELIVER_FAIL="$base/deliver.fail"
export FOLLOWUP_STATE_DIR="$base/state" FOLLOWUP_OUTBOX="$base/state/outbox.jsonl" FOLLOWUP_WORKER_ALIVE_CMD="$base/alive" FOLLOWUP_DELIVER_CMD="$base/deliver" FOLLOWUP_NOW="2026-11-08T12:00"
export SEATS_TABLE="$base/none.tsv" FOLLOWUP_STOP_FIRES_LOG="$base/state/fires.log"
mkdir -p "$HOME" "$FU_ALIVE_DIR"; unset WM_DIRECTOR TMUX; export WM_SEAT=ctl
row() { # row id rev due [claim] [waits_on-json] [extra-json]
  jq -nc --arg id "$1" --argjson rev "$2" --arg due "$3" --arg claim "${4:-}" --argjson w "${5:-[]}" --argjson x "${6:-{\}}" \
    '{ask_id:$id,owner:"ctl",rev:$rev,due:$due,status:"open",claim:(if $claim=="" then null else $claim end),waits_on:$w,what:"w"} + $x'; }
asks() { jq -sc . >"$FU_ASKS"; }
disp() { python3 -I "$EV" eval --seat ctl 2>/dev/null | jq -r --arg id "$1" '.dispositions[] | select(.id==$id) | .disposition'; }
newids() { python3 -I "$EV" new --seat ctl 2>/dev/null | jq -r '.new[].id' | paste -sd, -; }
stopsf() { printf '{"hook_event_name":"Stop","session_id":"s1","stop_hook_active":%s}' "${1:-false}" | FOLLOWUP_EVAL="$EV" bash "$SF" stop 2>/dev/null; }
stopowed() { printf '{"hook_event_name":"Stop","session_id":"s1","stop_hook_active":%s}' "${1:-false}" | FOLLOWUP_EVAL="$EV" bash "$OWED" hook 2>/dev/null; }

# 1. dispositions
touch "$FU_ALIVE_DIR/w-live"
{ row V1 1 2026-11-07T10:00 "" "[]" '{"acceptance":{"verdict":"PASS"}}'
  row C1 1 2026-11-07T10:00 "w-live@2099-01-01T00:00"
  row B1 1 2026-11-07T10:00 "" '[{"owner":"hermes","dependency":"event:x","next_check":"2026-11-09T09:00"}]'
  row R1 1 2026-11-07T10:00
  row O1 1 2026-11-07T10:00 "" "[]" '{"what":"waits-on=seat:rb PID 123 ACK"}'
  row S1 1 2026-11-07T10:00 "w-dead@2099-01-01T00:00"
  row D1 1 2099-01-01T00:00 "" '["DEP1"]'
  row DEP1 1 2099-01-01T00:00; } | asks
[ "$(disp V1)" = verified ]; chk "1: a PASS acceptance is verified" $?
[ "$(disp C1)" = claimed ]; chk "1: a live claim is claimed" $?
[ "$(disp B1)" = blocked ]; chk "1: a structured blocker is blocked" $?
[ "$(disp R1)" = ready ]; chk "1: an overdue unclaimed unblocked row is ready" $?
[ "$(disp O1)" = overdue-ack ]; chk "1: a prose waits-on / PID / ACK row is overdue-ack, not an accounted disposition" $?
[ "$(disp S1)" = stale-worker ]; chk "1: a claim by a dead worker is stale-worker" $?
[ "$(disp D1)" = blocked ]; chk "1: a row whose open dependency is still open is blocked, not ready" $?
# 2. dependency clearing => ready (the dependency leaves the open set)
{ row D1 1 2099-01-01T00:00 "" '["DEP1"]'; } | asks
[ "$(disp D1)" = ready ]; chk "2: once the dependency is gone the row is ready" $?
# 3. same blocked item through 3 stops: one escalation, no repeat citation (both hooks share the one fingerprint file)
row R1 1 2026-11-07T10:00 | asks
a="$(stopsf false)"; b="$(stopsf true)"; c="$(stopowed false)"
grep -q R1 <<<"$a"; chk "3: first stop (seat-followups) cites the id with a next action" $?
[ -z "$b" ] && [ -z "$c" ]; chk "3: second stop and the owed-now stop on the unchanged item stay silent (shared fingerprint)" $?
[ "$(wc -l <"$FOLLOWUP_OUTBOX" 2>/dev/null || echo 0)" = 1 ]; chk "3: one outbox entry" $?
[ -s "$FOLLOWUP_STATE_DIR/fingerprints.json" ] && jq -e . "$FOLLOWUP_STATE_DIR/fingerprints.json" >/dev/null; chk "3: one persisted fingerprint file, valid JSON" $?
ls "$FOLLOWUP_STATE_DIR" | grep -q '\.tmp'; [ $? -ne 0 ]; chk "3: no stray temp file after the atomic write" $?
# 4. next-check expiry re-escalates the same id
row B2 1 2026-11-07T10:00 "" '[{"owner":"hermes","dependency":"event:y","next_check":"2026-11-08T12:30"}]' | asks
[ -z "$(newids)" ]; chk "4: a live structured blocker raises nothing" $?
FOLLOWUP_NOW="2026-11-08T13:00" python3 -I "$EV" new --seat ctl | jq -e '.new[0].id=="B2"' >/dev/null; chk "4: expired next_check re-escalates B2" $?
# 5. independent task failure is not suppressed by the unchanged one
{ row R1 1 2026-11-07T10:00; row F1 1 2026-11-08T11:00 "w-dead@2099-01-01T00:00"; } | asks
[ "$(newids)" = F1 ]; chk "5: a new independent failure escalates alone" $?
# 6. healthy vs stale claim
row C2 1 2026-11-07T10:00 "w-live@2099-01-01T00:00" | asks; [ "$(disp C2)" = claimed ]; chk "6: healthy claim" $?
rm -f "$FU_ALIVE_DIR/w-live"; [ "$(disp C2)" = stale-worker ]; chk "6: same claim after the worker dies" $?
touch "$FU_ALIVE_DIR/w-live"
# 7. changed task revision re-escalates; revision-stale claim
row R1 2 2026-11-07T10:00 | asks; [ "$(newids)" = R1 ]; chk "7: changed revision is a new fingerprint" $?
row C3 5 2026-11-07T10:00 "w-live@2099-01-01T00:00" "[]" '{"claim_rev":4}' | asks; [ "$(disp C3)" = stale-worker ]; chk "7: a claim taken at an older revision is stale" $?
# 8. two concurrent evaluators yield one escalation
rm -rf "$FOLLOWUP_STATE_DIR"; row Z1 1 2026-11-07T10:00 | asks
for i in 1 2 3 4 5 6; do python3 -I "$EV" new --seat ctl >"$base/c$i.out" 2>/dev/null & done; wait
n="$(cat "$base"/c?.out | jq -r '.new[]?.id' | grep -c Z1)"; [ "$n" = 1 ]; chk "8: six concurrent evaluators produce exactly one escalation (got $n)" $?
# 9. restart / replay: fresh process, same state, nothing new
[ -z "$(newids)" ]; chk "9: a fresh process on persisted state raises nothing" $?
# 10. failed delivery then recovery
touch "$FU_DELIVER_FAIL"; : >"$FU_DELIVERED"
python3 -I "$EV" replay >/dev/null 2>&1; grep -q '"delivered":false' "$FOLLOWUP_OUTBOX"; chk "10: failed delivery leaves the entry queued" $?
rm -f "$FU_DELIVER_FAIL"; python3 -I "$EV" replay >/dev/null 2>&1; ! grep -q '"delivered":false' "$FOLLOWUP_OUTBOX"; chk "10: replay after recovery delivers it" $?
c1="$(wc -l <"$FU_DELIVERED")"; python3 -I "$EV" replay >/dev/null 2>&1; [ "$(wc -l <"$FU_DELIVERED")" = "$c1" ]; chk "10: and does not deliver twice" $?
# 11. malformed input fails visibly
rm -rf "$FOLLOWUP_STATE_DIR"; echo 'not json' >"$FU_ASKS"; FU_ASKS_GARBAGE=1 python3 -I "$EV" new --seat ctl | jq -e '.new[0].id=="LEDGER"' >/dev/null; chk "11: garbage ledger is a visible LEDGER obligation" $?
FU_ASKS_FAIL=3 python3 -I "$EV" eval --seat ctl | jq -e '.error != null' >/dev/null; chk "11: ledger command failure reports an error, never an empty pass" $?
echo '[{"ask_id":"X1","rev":1}]' >"$FU_ASKS"; python3 -I "$EV" eval --seat ctl | jq -e '.dispositions[0].id=="X1"' >/dev/null; chk "11: a row missing fields is still evaluated, not dropped" $?
echo "followup-eval: $pass PASS $fail FAIL"; [ "$fail" = 0 ]
