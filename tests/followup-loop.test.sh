#!/usr/bin/env bash
# followup loop repair (ledger ask A1307): the Stop gate blocks once per NEW actionable obligation (fingerprint persisted atomically), never recites an
# unchanged historical id, re-escalates on a new id / changed rev / expired next-check, treats a valid structured blocker or live claim as accounted
# (prose waits-on is not), fails visibly on a malformed ledger, and keeps an escalation outbox that survives delivery failure and replays.
# Both sides run the one evaluator .local/bin/followup-eval.py (ledger ask A1346); the bash copy is gone.
# The canonical ledger (wm-asks query --json) is a fixture; state lives in a tmp dir. No real ledger, no product build.
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
base="$(mktemp -d "${TMPDIR:-/tmp}/followup-loop.XXXXXX")"; trap 'rm -rf "$base"' EXIT
fail=0; pass=0
ok()  { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }
chk() { if [ "$2" = 0 ]; then ok "$1"; else bad "$1"; fi; }
GATE="$here/.claude/hooks/followup-stop-gate.sh"; OWED="$here/.claude/hooks/owed-now.sh"; LIB="$here/.claude/hooks/followup-lib.sh"
for f in "$GATE" "$OWED" "$LIB"; do bash -n "$f"; chk "bash -n $(basename "$f")" $?; done

# fake wm-asks: `query --owners X --status open --json` prints $FU_ASKS (a JSON array of rows); FU_ASKS_FAIL=n exits n; FU_ASKS_GARBAGE prints junk
cat >"$base/wm-asks" <<'FAKE'
#!/usr/bin/env bash
[ "${1:-}" = asks ] && [ "${2:-}" = query ] || exit 2
[ -n "${FU_ASKS_FAIL:-}" ] && exit "$FU_ASKS_FAIL"
[ -n "${FU_ASKS_GARBAGE:-}" ] && { echo 'not json'; exit 0; }
cat "$FU_ASKS"
FAKE
chmod +x "$base/wm-asks"
# fake worker liveness: alive iff a file named after the worker exists in $FU_ALIVE_DIR
cat >"$base/alive" <<'FAKE'
#!/usr/bin/env bash
[ -e "$FU_ALIVE_DIR/$1" ]
FAKE
chmod +x "$base/alive"
cat >"$base/deliver" <<'FAKE'
#!/usr/bin/env bash
cat >>"$FU_DELIVERED"; [ ! -e "$FU_DELIVER_FAIL" ]
FAKE
chmod +x "$base/deliver"
export HOME="$base/home" WM_ASKS_BIN="$base/wm-asks" FU_ASKS="$base/asks.json" FU_ALIVE_DIR="$base/alive.d" FU_DELIVERED="$base/delivered.log" FU_DELIVER_FAIL="$base/deliver.fail"
export FOLLOWUP_STATE_DIR="$base/state" FOLLOWUP_OUTBOX="$base/state/outbox.jsonl" FOLLOWUP_WORKER_ALIVE_CMD="$base/alive" FOLLOWUP_DELIVER_CMD="$base/deliver"
export FOLLOWUP_STOP_FIRES_LOG="$base/state/fires.log" SEATS_TABLE="$base/none.tsv" FOLLOWUP_NOW="2026-11-08T12:00"
mkdir -p "$HOME" "$FU_ALIVE_DIR"; unset WM_DIRECTOR TMUX; export WM_SEAT=ctl
row() { # row id rev due [claim] [waits_on-json]
  jq -nc --arg id "$1" --argjson rev "$2" --arg due "$3" --arg claim "${4:-}" --argjson w "${5:-[]}" \
    '{ask_id:$id,owner:"ctl",rev:$rev,due:$due,status:"open",ready:true,claim:(if $claim=="" then null else $claim end),waits_on:$w,what:"w",check:"c"}'; }
asks() { jq -sc . >"$FU_ASKS"; }
stop() { local sha="${1:-false}"; printf '{"hook_event_name":"Stop","session_id":"s1","stop_hook_active":%s}' "$sha" | bash "$GATE" 2>/dev/null; }
blocks() { jq -e '.decision=="block"' <<<"$1" >/dev/null 2>&1; }

# 1. same unchanged blocked state across 3 stops: exactly one block, then pass
row A1 1 2026-11-07T10:00 | asks
o1="$(stop false)"; o2="$(stop true)"; o3="$(stop false)"
blocks "$o1"; chk "1: first stop on an overdue unaccounted id blocks" $?
grep -q 'A1' <<<"$o1"; chk "1: the block names the id" $?
grep -qiE 'next|action' <<<"$o1"; chk "1: the block carries a specific next action" $?
[ -z "$o2" ] && [ -z "$o3" ]; chk "1: stops 2 and 3 on the unchanged state pass silently (no recital)" $?
[ "$(wc -l <"$FOLLOWUP_OUTBOX" 2>/dev/null || echo 0)" = 1 ]; chk "1: exactly one escalation outbox entry" $?
# 2. new id re-escalates; changed rev re-escalates; unchanged ones still pass
row A1 1 2026-11-07T10:00 >"$base/r1"; row A2 1 2026-11-07T11:00 >"$base/r2"; cat "$base/r1" "$base/r2" | asks
o="$(stop false)"; blocks "$o" && grep -q 'A2' <<<"$o" && ! grep -q 'A1' <<<"$o"; chk "2: a new id blocks naming only the new id" $?
row A1 2 2026-11-07T10:00 >"$base/r1"; cat "$base/r1" "$base/r2" | asks
o="$(stop false)"; blocks "$o" && grep -q 'A1' <<<"$o"; chk "2: a changed task revision re-escalates" $?
o="$(stop false)"; [ -z "$o" ]; chk "2: and then passes again" $?
# 3. genuine new failure is not suppressed by a standing one
row A1 2 2026-11-07T10:00 >"$base/r1"; row A2 1 2026-11-07T11:00 >"$base/r2"; row A3 1 2026-11-08T13:00 >"$base/r3"; cat "$base/r1" "$base/r2" "$base/r3" | asks
o="$(stop false)"; [ -z "$o" ]; chk "3: an A3 not yet due is not an obligation" $?
o="$(FOLLOWUP_NOW=2026-11-08T13:30 stop false)"; blocks "$o" && grep -q 'A3' <<<"$o" && ! grep -qE 'A1|A2' <<<"$o"; chk "3: a genuine new failure (A3 now due) blocks alone" $?
# 4. valid structured blocker accounts; prose waits-on does not; next-check expiry re-escalates
rm -rf "$FOLLOWUP_STATE_DIR"
b='[{"owner":"rb","dependency":"A900","next_check":"2026-11-09T09:00"}]'
row B1 1 2026-11-07T10:00 "" "$b" | asks
o="$(stop false)"; [ -z "$o" ]; chk "4: valid structured blocker (owner, dependency, future next_check) accounts for an overdue row" $?
row B1 1 2026-11-07T10:00 "" '[{"owner":"","dependency":"A900","next_check":"2026-11-09T09:00"}]' | asks
o="$(stop false)"; blocks "$o"; chk "4: empty owner is an invalid blocker and blocks" $?
rm -rf "$FOLLOWUP_STATE_DIR"
jq -nc '{ask_id:"B2",owner:"ctl",rev:1,due:"2026-11-07T10:00",status:"open",ready:true,claim:null,waits_on:[],what:"waits-on=seat:rb Monday hold",check:"c"}' | asks
o="$(stop false)"; blocks "$o"; chk "4: prose waits-on in the what column is not a structured blocker" $?
rm -rf "$FOLLOWUP_STATE_DIR"
row B1 1 2026-11-07T10:00 "" "$b" | asks; stop false >/dev/null
o="$(FOLLOWUP_NOW=2026-11-09T09:30 stop false)"; blocks "$o" && grep -q 'B1' <<<"$o"; chk "4: next_check expired re-escalates the same id" $?
rm -rf "$FOLLOWUP_STATE_DIR"
row B3 1 2026-11-07T10:00 "" '[{"owner":"rb","dependency":"A900","next_check":"2026-11-07T09:00"}]' | asks
o="$(stop false)"; blocks "$o"; chk "4: a blocker whose next_check is already past is invalid" $?
# 5. claims: live accounts, stale (dead worker) escalates, duplicate worker flagged
rm -rf "$FOLLOWUP_STATE_DIR"; touch "$FU_ALIVE_DIR/w-alive"
row C1 3 2026-11-07T10:00 "w-alive@2026-11-08T18:00" | asks
o="$(stop false)"; [ -z "$o" ]; chk "5: live claim (worker alive) accounts; owed-now sees no obligation" $?
row C1 3 2026-11-07T10:00 "w-dead@2026-11-08T10:00" | asks
o="$(stop false)"; blocks "$o" && grep -qiE 'stale|dead|failed' <<<"$o"; chk "5: claim by a dead worker is a stale claim and escalates" $?
# 6. owed-now lint: OVERDUE only for unaccounted rows (A1289 policy)
rm -rf "$FOLLOWUP_STATE_DIR"
{ row D1 1 2026-11-07T10:00 "w-alive@2026-11-08T18:00"; row D2 1 2026-11-07T10:00 "" "$b"; row D3 1 2026-11-07T10:00; } | asks
out="$(OPEN_ASKS="$base/none.tsv" OWED_NOW_SOURCE=asks bash "$OWED" lint --seat ctl --now 2026-11-08T12:00 2>&1)"
grep -q 'D3' <<<"$out" && ! grep -qE 'D1|D2' <<<"$out"; chk "6: owed-now flags only the unaccounted row, not live-claim or structured-blocker rows" $?
# 7. malformed ledger fails visibly, once
rm -rf "$FOLLOWUP_STATE_DIR"
o="$(FU_ASKS_GARBAGE=1 stop false)"; blocks "$o" && grep -qiE 'malformed|unreadable|ledger' <<<"$o"; chk "7: non-JSON ledger blocks visibly (no permissive closure)" $?
o="$(FU_ASKS_GARBAGE=1 stop false)"; [ -z "$o" ]; chk "7: the same ledger failure does not recite on the next stop" $?
rm -rf "$FOLLOWUP_STATE_DIR"
o="$(FU_ASKS_FAIL=3 stop false)"; blocks "$o"; chk "7: ledger command failure blocks visibly" $?
# 8. concurrent evaluators: N parallel stops on one new obligation produce one block, one outbox entry
rm -rf "$FOLLOWUP_STATE_DIR"; row E1 1 2026-11-07T10:00 | asks
for i in 1 2 3 4 5 6; do stop false >"$base/par.$i" & done; wait
n=0; for i in 1 2 3 4 5 6; do [ -s "$base/par.$i" ] && n=$((n + 1)); done
[ "$n" = 1 ]; chk "8: six concurrent evaluators yield exactly one block (got $n)" $?
[ "$(wc -l <"$FOLLOWUP_OUTBOX")" = 1 ]; chk "8: and exactly one outbox entry" $?
# 9. outbox survives delivery failure and replays
rm -rf "$FOLLOWUP_STATE_DIR" "$FU_DELIVERED"; touch "$FU_DELIVER_FAIL"; row F1 1 2026-11-07T10:00 | asks
stop false >/dev/null
[ -s "$FOLLOWUP_OUTBOX" ] && [ ! -s "$FU_DELIVERED" ] || [ -s "$FU_DELIVERED" ]; chk "9: entry is queued in the outbox when delivery fails" $?
grep -q '"delivered":true' "$FOLLOWUP_OUTBOX" 2>/dev/null; r=$?; [ "$r" != 0 ]; chk "9: the failed entry is not marked delivered" $?
rm -f "$FU_DELIVER_FAIL"; : >"$FU_DELIVERED"
bash -c ". '$LIB'; fu_outbox_replay" >/dev/null 2>&1
grep -q 'F1' "$FU_DELIVERED"; chk "9: replay after recovery delivers the entry" $?
grep -q '"delivered":true' "$FOLLOWUP_OUTBOX"; chk "9: and marks it delivered" $?
: >"$FU_DELIVERED"; bash -c ". '$LIB'; fu_outbox_replay" >/dev/null 2>&1; [ ! -s "$FU_DELIVERED" ]; chk "9: a second replay does not re-deliver" $?
# 10. restart/replay: state persists across processes (a fresh evaluator does not recite)
o="$(stop false)"; [ -z "$o" ]; chk "10: a fresh process on persisted state passes" $?
# 11. non-seat and subagent sessions are never gated
rm -rf "$FOLLOWUP_STATE_DIR"; row G1 1 2026-11-07T10:00 | asks
o="$(WM_SEAT= stop false)"; [ -z "$o" ]; chk "11: no WM_SEAT passes" $?
o="$(printf '{"hook_event_name":"Stop","session_id":"s1","agent_id":"x"}' | bash "$GATE" 2>/dev/null)"; [ -z "$o" ]; chk "11: a subagent passes" $?
# 11b. a child session that inherited WM_SEAT (sid differs from seats.tsv) passes; the seat's own sid is gated
printf 'ctl\toperator\tsid-real\t30\n' >"$base/seats.tsv"
o="$(printf '{"hook_event_name":"Stop","session_id":"sid-child"}' | SEATS_TABLE="$base/seats.tsv" bash "$GATE" 2>/dev/null)"; [ -z "$o" ]; chk "11: a child session with a foreign sid passes" $?
o="$(printf '{"hook_event_name":"Stop","session_id":"sid-real"}' | SEATS_TABLE="$base/seats.tsv" bash "$GATE" 2>/dev/null)"; blocks "$o"; chk "11: the seat's own sid is gated" $?
# 11c. WM_DIRECTOR=hermes reports instead of blocking
rm -rf "$FOLLOWUP_STATE_DIR"
o="$(printf '{"hook_event_name":"Stop","session_id":"s1"}' | WM_DIRECTOR=hermes bash "$GATE" 2>/dev/null)"; grep -q 'report-not-block' <<<"$o" && grep -q G1 <<<"$o"; chk "11: under WM_DIRECTOR=hermes the new obligation is reported, not blocked" $?
# 12. no cap flags introduced
! grep -nE 'OVERRIDE|--max-(turns|budget)|STOP_MAX' "$GATE" >/dev/null; chk "12: the gate carries no override/turn/budget cap" $?
# ---- FIX2 (ledger ask A1307, independent verifier findings) ----
LEASE=2026-11-08T18:00
# 13. one lock around outbox append and replay; outbox entry written before the fingerprint
rm -rf "$FOLLOWUP_STATE_DIR" "$FU_DELIVERED"; mkdir -p "$FOLLOWUP_STATE_DIR"; row H1 1 2026-11-07T10:00 | asks
(FOLLOWUP_OUTBOX=/nonexistent-dir/outbox.jsonl stop false >/dev/null)
[ ! -s "$FOLLOWUP_STATE_DIR/fingerprints.json" ]; chk "13: a failed outbox write leaves no fingerprint recorded (outbox entry is written first)" $?
o="$(stop false)"; blocks "$o" && grep -q H1 <<<"$o"; chk "13: and the next stop still escalates that obligation" $?
rm -rf "$FOLLOWUP_STATE_DIR" "$FU_DELIVERED"; mkdir -p "$FOLLOWUP_STATE_DIR"; printf '{"id":"Z","fp":"Z|1|overdue|","delivered":false}\n' >"$FOLLOWUP_OUTBOX"
( flock -x 9; sleep 3 ) 9>"$FOLLOWUP_STATE_DIR/lock" & sleep 0.4
( bash -c ". '$LIB'; fu_outbox_replay" >/dev/null 2>&1 & ); sleep 1
[ ! -s "$FU_DELIVERED" ]; chk "13: replay waits on the same lock append uses" $?
wait; sleep 1; grep -q Z "$FU_DELIVERED"; chk "13: and delivers once that lock is released" $?
rm -rf "$FOLLOWUP_STATE_DIR" "$FU_DELIVERED"; : >"$FU_DELIVERED"
for i in $(seq 1 25); do row "K$i" 1 2026-11-07T10:00; done | asks
( for _ in $(seq 1 30); do bash -c ". '$LIB'; fu_outbox_replay" >/dev/null 2>&1; done ) & rp=$!
stop false >/dev/null; wait "$rp"
[ "$(jq -s 'length' "$FOLLOWUP_OUTBOX")" = 25 ]; chk "13: replay running beside append loses no outbox entry" $?
# 14. timer-driven replay, no model turn, with a delivery command that is set by default
SD="$here/.config/systemd/user"; RS="$here/.local/bin/followup-outbox-replay.sh"; DL="$here/.local/bin/followup-deliver.sh"
[ -x "$RS" ] && bash -n "$RS"; chk "14: followup-outbox-replay.sh exists, executable, parses" $?
[ -x "$DL" ] && bash -n "$DL"; chk "14: followup-deliver.sh exists, executable, parses" $?
grep -q 'followup-outbox-replay.sh' "$SD/followup-outbox-replay.service" 2>/dev/null && grep -q 'Type=oneshot' "$SD/followup-outbox-replay.service"; chk "14: oneshot service runs the replay script" $?
grep -qE 'OnUnitActiveSec=[0-9]+(min|s)' "$SD/followup-outbox-replay.timer" 2>/dev/null && grep -q 'timers.target' "$SD/followup-outbox-replay.timer"; chk "14: timer re-runs it on an interval and installs into timers.target" $?
! grep -qiE '(^|[ (;|])claude +-|anthropic|systemd-run' "$RS" "$DL" 2>/dev/null; chk "14: replay and deliver scripts start no model turn" $?
rm -rf "$FOLLOWUP_STATE_DIR" "$FU_DELIVERED"; mkdir -p "$FOLLOWUP_STATE_DIR"
printf '#!/usr/bin/env bash\necho "$*" >>"%s"\n' "$base/seat-event.log" >"$base/seat-event"; chmod +x "$base/seat-event"
printf '{"id":"Q1","kind":"overdue","detail":"d","seat":"ctl","delivered":false}\n' >"$FOLLOWUP_OUTBOX"
( unset FOLLOWUP_DELIVER_CMD; SEAT_EVENT_BIN="$base/seat-event" bash "$RS" >/dev/null 2>&1 )
grep -q 'ctl' "$base/seat-event.log" 2>/dev/null && grep -q Q1 "$base/seat-event.log" && grep -q '"delivered":true' "$FOLLOWUP_OUTBOX"; chk "14: with FOLLOWUP_DELIVER_CMD unset the timer script delivers via the seat event bell and marks delivered" $?
# 15. rows with an empty or foreign owner are obligations, not silently skipped
rm -rf "$FOLLOWUP_STATE_DIR"
jq -nc '{ask_id:"N1",owner:"",rev:1,due:"2026-11-07T10:00",status:"open",claim:null,waits_on:[]}' | asks
o="$(stop false)"; blocks "$o" && grep -q N1 <<<"$o"; chk "15: an overdue row with an empty owner escalates" $?
rm -rf "$FOLLOWUP_STATE_DIR"
jq -nc '{ask_id:"N2",owner:"nobody-seat",rev:1,due:"2026-11-07T10:00",status:"open",claim:null,waits_on:[]}' | asks
o="$(stop false)"; blocks "$o" && grep -q N2 <<<"$o"; chk "15: an overdue row with a foreign owner escalates" $?
rm -rf "$FOLLOWUP_STATE_DIR"
jq -nc '{ask_id:"N3",owner:"rb",rev:1,due:"2026-11-07T10:00",status:"open",claim:null,waits_on:[]}' | asks
o="$(stop false)"; [ -z "$o" ]; chk "15: a known other seat's row is still left to that seat" $?
# 16. claim validity: lease, session, task revision (not worker liveness alone)
rm -rf "$FOLLOWUP_STATE_DIR"; touch "$FU_ALIVE_DIR/w-alive"
row L1 1 2026-11-07T10:00 "w-alive@2026-11-08T11:00" | asks
o="$(stop false)"; blocks "$o" && grep -qiE 'lease|stale' <<<"$o"; chk "16: a live worker with an expired lease is a stale claim" $?
rm -rf "$FOLLOWUP_STATE_DIR"
row L2 1 2026-11-07T10:00 "w-alive@$LEASE" | asks
o="$(stop false)"; [ -z "$o" ]; chk "16: a live worker with an unexpired lease still accounts" $?
rm -rf "$FOLLOWUP_STATE_DIR"
row L3 2 2026-11-07T10:00 "w-alive@$LEASE" | jq -c '. + {claim_rev:1}' | asks
o="$(stop false)"; blocks "$o" && grep -qiE 'revision|rev' <<<"$o"; chk "16: a claim taken at an older task revision is stale" $?
rm -rf "$FOLLOWUP_STATE_DIR"
row L4 1 2026-11-07T10:00 "w-alive@$LEASE" | jq -c '. + {claim_session:"sess-dead"}' | asks
o="$(stop false)"; blocks "$o" && grep -qiE 'session|stale' <<<"$o"; chk "16: a claim whose owning session is dead is stale though the worker name is live" $?
touch "$FU_ALIVE_DIR/sess-ok"; rm -rf "$FOLLOWUP_STATE_DIR"
row L5 1 2026-11-07T10:00 "w-gone@$LEASE" | jq -c '. + {claim_session:"sess-ok"}' | asks
o="$(stop false)"; [ -z "$o" ]; chk "16: a live owning session accounts for the claim" $?
# 17. a required verifier still blocks an unsafe ending action
rm -rf "$FOLLOWUP_STATE_DIR"
row V1 1 2026-11-07T10:00 "w-alive@$LEASE" | jq -c '. + {verifier_required:true, ending:true}' | asks
o="$(stop false)"; blocks "$o" && grep -q V1 <<<"$o" && grep -qiE 'verifier' <<<"$o"; chk "17: an ending action on a verifier-required row with no PASS acceptance blocks despite a live claim" $?
rm -rf "$FOLLOWUP_STATE_DIR"
row V2 1 2026-11-07T10:00 "w-alive@$LEASE" | jq -c '. + {verifier_required:true, ending:true, acceptance:{verdict:"FAIL"}}' | asks
o="$(stop false)"; blocks "$o" && grep -q V2 <<<"$o"; chk "17: a FAIL acceptance does not clear the verifier requirement" $?
rm -rf "$FOLLOWUP_STATE_DIR"
row V3 1 2026-11-07T10:00 "w-alive@$LEASE" | jq -c '. + {verifier_required:true, ending:true, acceptance:{verdict:"PASS"}}' | asks
o="$(stop false)"; [ -z "$o" ]; chk "17: a PASS acceptance clears it" $?
rm -rf "$FOLLOWUP_STATE_DIR"
row V4 1 2026-11-07T10:00 "w-alive@$LEASE" | jq -c '. + {verifier_required:true}' | asks
o="$(stop false)"; [ -z "$o" ]; chk "17: a verifier-required row not being ended is not blocked" $?
echo "followup-loop: $pass PASS $fail FAIL"; [ "$fail" = 0 ]
