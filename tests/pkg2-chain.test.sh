#!/usr/bin/env bash
# pkg2-chain.test.sh (A1296 package 2 repair 7, rv7 F7-1): the whole registered Stop chain, every synchronous Stop hook of .claude/settings.json in registered order,
# driven under (a) the fingerprint-store lock held by another process for 9 s and (b) the lock free but the delivery command slow (9 s). The total Stop-chain wall time is
# the measurement, not one hook. Also: nothing lost / nothing delivered twice across the chain and the durable consumer (followup-outbox-replay.sh, the existing timer script).
# Hermetic: HOME, state and stubs under a temp dir; wm-asks / wm-decide / agorabus / the delivery command are stubs; the real ledger and the real hooks are never touched.
# Usage: pkg2-chain.test.sh [repo-root]  (point it at the prev tree to see the RED side; each hook is bounded by `timeout` inside the test, never by the hook).
# Async Stop hooks (peon, recall-*, summa-answer-candidate) are excluded from the wall time: they do not hold the Stop event.
set -u
R="${1:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
W="$(mktemp -d "${TMPDIR:-/tmp}/chain.XXXXXX")"; trap 'pkill -f "$W" 2>/dev/null; rm -rf "$W"' EXIT
p=0; f=0; ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1 (got [$2] want [$3])"; fi; }
export HOME="$W/home"; mkdir -p "$HOME" "$W/bin"; export TMPDIR="$W"
unset WM_DIRECTOR WM_HELPER FOLLOWUP_TRACE OWED_NOW_SOURCE OPEN_ASKS WM_SEAT
export PATH="$W/bin:/usr/local/bin:/usr/bin:/bin" WM_ASKS_BIN="$W/bin/wm-asks" WM_DECIDE_BIN="$W/bin/wm-decide" ASIDE_WM_ASKS_BIN="$W/bin/wm-asks"
export FOLLOWUP_STATE_DIR="$W/st" FOLLOWUP_OUTBOX="$W/st/outbox.jsonl" FOLLOWUP_DELIVER_CMD="$W/bin/deliver" OWED_NOW_STATE="$W/owed" ASIDE_STOP_LOG="$W/fires.log" SEATS_TABLE="$W/seats.tsv"
export FOLLOWUP_STOP_FIRES_LOG="$W/gate.log" SEAT_FOLLOWUPS_LOG_DIR="$W/sf" FLEET_DASH_DIR="$W/dash" NAJ_STATE_DIR="$W/naj" AGORABUS_INTENT_STATE_DIR="$W/ab" FOLLOWUP_NOW=2026-11-13T12:00
printf 'ctl\t1\tsid-ctl\n' >"$W/seats.tsv"
printf '#!/bin/bash\necho "{\\"owed\\":0,\\"overdue\\":0,\\"escalated\\":0,\\"ids\\":[]}"\n' >"$W/bin/wm-decide"
printf '#!/bin/bash\nexit 0\n' >"$W/bin/agorabus"
cat >"$W/bin/wm-asks" <<'STUB'
#!/bin/bash
d="$(cat "@W@/delay" 2>/dev/null)"; [ -z "$d" ] || sleep "$d"
cat "@W@/rows.json"
STUB
cat >"$W/bin/deliver" <<'STUB'
#!/bin/bash
cat >/dev/null; d="$(cat "@W@/ddelay" 2>/dev/null)"; [ -z "$d" ] || sleep "$d"; echo x >>"@W@/deliver.log"
STUB
sed -i "s#@W@#$W#g" "$W/bin/wm-asks" "$W/bin/deliver"; chmod +x "$W/bin/"*
echo '[{"ask_id":"T1","rev":1,"owner":"ctl","due":"2026-11-12T09:00","what":"owed thing"}]' >"$W/rows.json"
now(){ date +%s.%N; }
dt(){ awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", b-a}'; }
under(){ awk -v t="$1" -v lim="$2" 'BEGIN{print (t<=lim)?"ok":"slow " t}'; }

# the registered synchronous Stop chain, in order, resolved into this tree (settings.json is read, never hardcoded)
CHAIN=(); SKIPPED=0
while IFS= read -r cmd; do
  set -- $cmd; hook="$1"; shift; base="${hook##*/}"
  for d in "$R/.claude/hooks" "$R/.claude/scripts" "$R/.local/bin"; do [ -f "$d/$base" ] && { CHAIN+=("$d/$base${*:+ $*}"); continue 2; }; done
  SKIPPED=$((SKIPPED+1))
done < <(jq -r '.hooks.Stop[].hooks[] | select((.async // false) | not) | .command' "$R/.claude/settings.json")
ck "chain: the registered synchronous Stop chain resolves in this tree (hooks found / not in tree)" "${#CHAIN[@]}/$SKIPPED" "9/0"
case " ${CHAIN[*]} " in *followup-stop-gate.sh*seat-followups.sh*owed-now.sh*) c=ordered ;; *) c=missing ;; esac
ck "chain: the three store-lock hooks are in the chain in registered order" "$c" ordered

IN="$(jq -nc '{hook_event_name:"Stop",session_id:"sid-ctl",stop_hook_active:false,last_assistant_message:"ok"}')"
# run_chain: every hook in order, WM_SEAT=ctl; sets CT (wall seconds), CBLOCKS (hooks that printed a block), COUT (per-hook outputs)
run_chain() {
  local t0 t1 h out; CBLOCKS=0; COUT=""; t0=$(now)
  for h in "${CHAIN[@]}"; do
    out="$(printf '%s' "$IN" | WM_SEAT=ctl SEAT_OWED_BIN="$R/.local/bin/seat-owed.sh" timeout 60 bash $h 2>/dev/null)"
    COUT="$COUT$out"$'\n'
    jq -e '.decision=="block"' <<<"$out" >/dev/null 2>&1 && CBLOCKS=$((CBLOCKS+1))
  done
  t1=$(now); CT="$(dt "$t0" "$t1")"
}
fresh(){ pkill -f "$W/st" 2>/dev/null; rm -rf "$W/st" "$W/owed" "$W/sf" "$W/gate.log" "$W/fires.log" "$W/deliver.log" "$W/naj"; : >"$W/delay"; : >"$W/ddelay"; mkdir -p "$W/st"; : >"$W/deliver.log"; }

# baseline: lock free, delivery instant, nothing owed (rows empty) => the chain's own cost on this host right now
fresh; echo '[]' >"$W/rows.json"; run_chain; BASE="$CT"; echo "INFO chain baseline (no lock, no delay, nothing owed): ${BASE}s"
echo '[{"ask_id":"T1","rev":1,"owner":"ctl","due":"2026-11-12T09:00","what":"owed thing"}]' >"$W/rows.json"

# --- (a) store lock held by another process for 9 s: the chain must not wait on it
fresh
( exec 9>"$W/st/lock"; flock -x 9; echo $BASHPID >"$W/hold.pid"; exec sleep 9 ) & lk=$!; sleep 0.4   # the holder IS the sleep (exec), so killing its pid releases the lock
run_chain; HELD="$CT"; HB="$CBLOCKS"; kill "$(cat "$W/hold.pid")" 2>/dev/null; wait $lk 2>/dev/null   # release the holder: the chain returns before its 9 s are up
echo "INFO chain with the store lock held 9 s: ${HELD}s (baseline ${BASE}s)"
ck "F7-1a lock held 9 s: total Stop-chain wall time within baseline + 4 s (no hook waits on the lock)" "$(under "$HELD" "$(awk -v b="$BASE" 'BEGIN{print b+4}')")" ok
ck "F7-1a lock held: no hook blocked on an obligation it could not record" "$HB" 0
UPSO="$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"sid-ctl"}' | WM_SEAT=ctl bash "$R/.claude/hooks/owed-now.sh" hook 2>/dev/null)"
ck "F7-1a lock held: the next prompt says the Stop check was skipped (truthful marker, not none owed)" "$(grep -c 'STOP CHECK SKIPPED' <<<"$UPSO")" 1
# nothing lost: lock free again, the next chain escalates T1 exactly once, the one after passes
run_chain; B2="$CBLOCKS"; run_chain; B3="$CBLOCKS"
ck "F7-1a nothing lost: after release the chain escalates T1 exactly once (one hook blocks), the next chain passes" "$B2/$B3" "1/0"
ck "F7-1a one outbox entry for T1 (fingerprint written once across three hooks)" "$(grep -c '"id":"T1"' "$W/st/outbox.jsonl" 2>/dev/null)" 1

# --- (b) lock free, delivery command slow (9 s) with an undelivered entry queued: the chain must not deliver inline
fresh
echo '{"id":"PRE","rev":1,"disposition":"ready","kind":"overdue","owner":"ctl","fp":"PRE|1|ready|overdue","seat":"ctl","ts":"2026-11-13T11:00:00+00:00","delivered":false}' >"$W/st/outbox.jsonl"
echo 9 >"$W/ddelay"
run_chain; SLOW="$CT"
echo "INFO chain with a 9 s delivery command, lock free: ${SLOW}s (baseline ${BASE}s)"
ck "F7-1b slow delivery, lock free: total Stop-chain wall time within baseline + 4 s (delivery is not inline)" "$(under "$SLOW" "$(awk -v b="$BASE" 'BEGIN{print b+4}')")" ok
ck "F7-1b the Stop chain delivered nothing inline (the entry waits for the durable consumer)" "$(wc -l <"$W/deliver.log" 2>/dev/null | tr -d ' ')" 0
# the durable consumer (existing timer script) delivers every outbox entry exactly once, a second run delivers nothing
: >"$W/ddelay"; touch "$W/deliver.log"
bash "$R/.local/bin/followup-outbox-replay.sh" >/dev/null 2>&1; D1="$(wc -l <"$W/deliver.log" | tr -d ' ')"; N1="$(grep -c '"id"' "$W/st/outbox.jsonl")"
bash "$R/.local/bin/followup-outbox-replay.sh" >/dev/null 2>&1; D2="$(wc -l <"$W/deliver.log" | tr -d ' ')"
ck "F7-1b the durable consumer delivers each outbox entry once (PRE and T1), the second run delivers nothing more" "$D1/$N1/$D2" "2/2/2"
run_chain
ck "F7-1b a later chain neither re-escalates nor re-delivers" "$CBLOCKS/$(wc -l <"$W/deliver.log" | tr -d ' ')" "0/2"

# --- (c) a chain racing a held lock, more chains, and the consumer racing a chain: one escalation, one delivery per entry
fresh
( flock -x "$W/st/lock" sleep 2 ) & lk=$!; sleep 0.3
run_chain & c1=$!
wait $lk 2>/dev/null; wait $c1 2>/dev/null
run_chain; run_chain
( bash "$R/.local/bin/followup-outbox-replay.sh" >/dev/null 2>&1 ) & ( run_chain ) & wait
bash "$R/.local/bin/followup-outbox-replay.sh" >/dev/null 2>&1
ck "F7-1c racing chains, held lock, consumer: T1 has exactly one outbox entry and exactly one delivery" "$(grep -c '"id":"T1"' "$W/st/outbox.jsonl")/$(wc -l <"$W/deliver.log" | tr -d ' ')" "1/1"

# --- (d) the durable consumer is mid-delivery (it holds the store lock while a 4 s delivery runs) when a chain runs: the chain neither waits nor re-delivers, then T1 is escalated
# exactly once and every outbox entry is delivered exactly once (no obligation lost, no double delivery on the new path)
fresh
echo '{"id":"PRE","rev":1,"disposition":"ready","kind":"overdue","owner":"ctl","fp":"PRE|1|ready|overdue","seat":"ctl","ts":"2026-11-13T11:00:00+00:00","delivered":false}' >"$W/st/outbox.jsonl"
echo 4 >"$W/ddelay"
( python3 -I "$R/.local/bin/followup-eval.py" replay >/dev/null 2>&1 ) & rp=$!; sleep 0.8
run_chain; MID="$CT"; MB="$CBLOCKS"; wait $rp 2>/dev/null
echo "INFO chain while the consumer holds the store lock mid-delivery: ${MID}s (baseline ${BASE}s)"
ck "F7-1d chain while the consumer is mid-delivery: within baseline + 3 s and blocks nothing it could not record" "$(under "$MID" "$(awk -v b="$BASE" 'BEGIN{print b+3}')")/$MB" "ok/0"
: >"$W/ddelay"; run_chain; MB2="$CBLOCKS"; run_chain; MB3="$CBLOCKS"
python3 -I "$R/.local/bin/followup-eval.py" replay >/dev/null 2>&1; python3 -I "$R/.local/bin/followup-eval.py" replay >/dev/null 2>&1
ck "F7-1d afterwards T1 is escalated once (not lost, not twice), PRE and T1 are each delivered exactly once" "$MB2/$MB3/$(grep -c '"id":"T1"' "$W/st/outbox.jsonl")/$(wc -l <"$W/deliver.log" | tr -d ' ')" "1/0/1/2"
echo "pass=$p fail=$f"; [ "$f" = 0 ]
