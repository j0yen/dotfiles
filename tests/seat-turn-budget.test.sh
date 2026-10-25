#!/usr/bin/env bash
# seat-turn-budget (five-whys 2026-10-24 r7-cap-killed-turn-minutes): a seat turn has a stopping rule before the 3420 s cap kill, and an exit-124 kill no longer
# re-delivers the same pile. Stubs only: a fake claude, a throwaway seats table + state dir; no real claude, unit or timer is started.
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }
H="$here/.claude/hooks/seat-turn-budget.sh"; TICK="$here/.local/bin/seat-tick.sh"; ASK="$here/.local/bin/seat-ask.sh"
SET="$here/.config/claude-seat/settings.json"; CTLSET="$here/.config/claude-seat/ctl-settings.json"

bash -n "$H" && ok "bash -n seat-turn-budget.sh" || bad "bash -n seat-turn-budget.sh"
[ -x "$H" ] && ok "hook executable" || bad "hook not executable"

# ---- hook: stdin JSON in, deny JSON out -----------------------------------------------------------
call() {  # call <deadline|""> <now> <tool> <tool_input-json>   -> stdout of the hook
  local dl="$1" now="$2" t="$3" i="$4"
  if [ -n "$dl" ]; then jq -nc --arg t "$t" --argjson i "$i" '{tool_name:$t,tool_input:$i}' | env SEAT_TURN_DEADLINE="$dl" SEAT_TURN_NOW="$now" bash "$H"
  else jq -nc --arg t "$t" --argjson i "$i" '{tool_name:$t,tool_input:$i}' | env -u SEAT_TURN_DEADLINE SEAT_TURN_NOW="$now" bash "$H"; fi
}
denied() { jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1; }
[ -z "$(call "" 1000 Agent '{"subagent_type":"coder"}')" ] && ok "no deadline: coder Agent allowed (not a seat turn)" || bad "no deadline must allow"
[ -z "$(call "" 1000 Bash '{"command":"timeout 99999 ls"}')" ] && ok "no deadline: long timeout allowed" || bad "no deadline long timeout"
call 9000 1000 Agent '{"subagent_type":"coder"}' | denied && ok "coder Agent denied in a seat turn" || bad "coder Agent not denied"
call 9000 1000 Agent '{"subagent_type":"coder-opus"}' | denied && ok "coder-opus Agent denied" || bad "coder-opus not denied"
[ -z "$(call 9000 1000 Agent '{"subagent_type":"verifier"}')" ] && ok "verifier Agent with budget left allowed" || bad "verifier Agent wrongly denied"
call 1500 1000 Agent '{"subagent_type":"verifier"}' | denied && ok "Agent 500 s before the deadline denied (within 600 s)" || bad "Agent near deadline not denied"
call 9000 1000 Bash '{"command":"timeout 99999 sleep 1"}' | denied && ok "Bash 'timeout 99999' denied" || bad "timeout 99999 not denied"
[ -z "$(call 9000 1000 Bash '{"command":"echo \"timeout 99999\""}')" ] && ok "quoted echo \"timeout 99999\" allowed (not command position)" || bad "quoted timeout wrongly denied"
[ -z "$(call 9000 1000 Bash '{"command":"grep -r timeout 3600 ."}')" ] && ok "'grep timeout 3600' allowed" || bad "grep timeout wrongly denied"
call 9000 1000 Bash '{"command":"cd x && timeout 99999 cmd"}' | denied && ok "'&& timeout 99999 cmd' denied" || bad "&& timeout not denied"
call 9000 1000 Bash '{"command":"sudo timeout 99999 cmd"}' | denied && ok "'sudo timeout 99999 cmd' denied" || bad "sudo timeout not denied"
call 9000 1000 Bash '{"command":"env FOO=1 timeout 99999 cmd"}' | denied && ok "'env FOO=1 timeout 99999 cmd' denied" || bad "env timeout not denied"
call 9000 1000 Bash '{"command":"a | (timeout 99999 cmd)"}' | denied && ok "'( timeout 99999' denied" || bad "paren timeout not denied"
[ -z "$(call 9000 1000 Bash '{"command":"timeout 30 ls"}')" ] && ok "Bash 'timeout 30' allowed" || bad "timeout 30 wrongly denied"
r="$(call 5000 5000 Read '{"file_path":"/x"}')"
printf '%s' "$r" | denied && [[ "$r" == *"turn budget spent: print STATUS and end"* ]] && ok "any tool at the deadline denied with the STATUS message" || bad "tool at deadline"
call 5000 7000 Bash '{"command":"ls"}' | denied && ok "any tool past the deadline denied" || bad "tool past deadline"
bash "$H" --selftest >"$tmp/hs" 2>&1 && ok "hook --selftest ($(grep -c '^PASS' "$tmp/hs") checks)" || bad "hook --selftest"

# ---- settings: hook registered, Monitor + ScheduleWakeup denied ------------------------------------
jq -e . "$SET" >/dev/null && ok "claude-seat settings.json parses" || bad "settings.json parses"
n="$(jq -r '[.hooks.PreToolUse[]?.hooks[]? | select(.command|test("seat-turn-budget[.]sh$"))] | length' "$SET")"
[ "$n" = 1 ] && ok "seat-turn-budget.sh registered once under hooks.PreToolUse" || bad "hook registered $n times (want 1)"
jq -e '.permissions.deny | index("ScheduleWakeup") != null and index("Monitor") != null' "$SET" >/dev/null && ok "seat settings deny ScheduleWakeup and Monitor" || bad "seat settings deny list"
jq -e '.permissions.deny | index("ScheduleWakeup") != null' "$CTLSET" >/dev/null && ok "ctl-settings.json denies ScheduleWakeup" || bad "ctl-settings deny"
jq -e . "$CTLSET" >/dev/null && ok "ctl-settings.json parses" || bad "ctl-settings parses"
n="$(jq -r '[.hooks.PreToolUse[]?.hooks[]? | select(.command|test("seat-turn-budget[.]sh$"))] | length' "$CTLSET")"
[ "$n" = 1 ] && ok "ctl-settings registers seat-turn-budget.sh once under hooks.PreToolUse" || bad "ctl hook registered $n times (want 1)"
[ "$(jq -c '.hooks.PreToolUse' "$CTLSET")" = "$(jq -c '.hooks.PreToolUse' "$SET")" ] && ok "ctl hook entry identical to settings.json's" || bad "ctl hook entry differs"

# ---- seat-ask: OnFailure on the transient unit; the template exists --------------------------------
[ -f "$here/.config/systemd/user/seat-tick-failed@.service" ] && ok "seat-tick-failed@.service template exists" || bad "template missing"
printf '# t\ntst\trb\tselftest-sid-%s\t20\t100\t^x\t-\n' "$$" >"$tmp/askseats.tsv"
out="$(SEATS_TABLE="$tmp/askseats.tsv" EVENTS_DIR="$tmp/askev" SEAT_ASK_DRY=1 SEAT_ASK_TICK_BIN="$tmp/fake-tick" EVENT_SOURCE=t "$ASK" tst "hello" 2>&1)"
[[ "$out" == *"--unit seat-ask-tst-"*" -p OnFailure=seat-tick-failed@tst.service "* ]] && ok "seat-ask unit carries -p OnFailure=seat-tick-failed@<seat>.service" || bad "seat-ask OnFailure missing: $out"

# ---- source order: the state read sits under the lock ----------------------------------------------
lk="$(grep -n 'elif ! flock -w "\$W" 9' "$TICK" | head -1 | cut -d: -f1)"; nh="$(grep -n '^note_holder$' "$TICK" | head -1 | cut -d: -f1)"
ls_def="$(grep -n '^load_state() {' "$TICK" | head -1 | cut -d: -f1)"; ls_last="$(grep -n '^load_state' "$TICK" | grep -v 'load_state() {' | tail -1 | cut -d: -f1)"
[ -n "$lk" ] && [ -n "$nh" ] && [ -n "$ls_last" ] && [ "$nh" -gt "$lk" ] && [ "$ls_last" -gt "$nh" ] && ok "load_state is called after the lock is taken (flock :$lk, note_holder :$nh, load_state :$ls_last)" || bad "state read not after the lock ($lk/$nh/$ls_last)"
fe="$(awk -v d="$ls_def" 'NR>d && /^}/ {print NR; exit}' "$TICK")"; ev="$(grep -n "^S_evoff=\"\$(sget" "$TICK" | cut -d: -f1)"
[ "$(wc -w <<<"$ev")" = 1 ] && [ "$ev" -gt "$ls_def" ] && [ "$ev" -lt "$fe" ] && ok "the S_evoff saved-state read exists once, inside load_state() (:$ev in :$ls_def-:$fe)" || bad "S_evoff read outside load_state ($ev / $ls_def-$fe)"
dl="$(grep -n '^export SEAT_TURN_DEADLINE=' "$TICK" | cut -d: -f1)"; ex="$(grep -n 'exec timeout -k 30 "\$CAP"' "$TICK" | cut -d: -f1)"
[ -n "$dl" ] && [ "$dl" -gt "$lk" ] && [ "$dl" -lt "$ex" ] && ok "SEAT_TURN_DEADLINE exported after the lock, before the claude exec" || bad "deadline export order ($lk/$dl/$ex)"
grep -q 'SEAT_TURN_DEADLINE=\$(( start + CAP - 900 ))' "$TICK" && ok "deadline = start + CAP - 900" || bad "deadline formula"

# ---- rc=124 path through the real seat-tick.sh with a stub claude ----------------------------------
D="$tmp/dash"; mkdir -p "$D"
SID="selftest-sid-$$-capkill"
printf '# t\ntst\trb\t%s\t20\t3600\t^/goal TST\t-\t80\n' "$SID" >"$tmp/seats.tsv"
printf 'rb test-model-rb\n' >"$tmp/mrc"; printf '/goal TST: line\n' >"$tmp/goal.md"; : >"$tmp/approvals.log"; echo 'CLAUDE_CODE_OAUTH_TOKEN=fake' >"$tmp/oauth.conf"
cat >"$tmp/claude" <<'FAKE'
#!/bin/bash
echo "deadline=${SEAT_TURN_DEADLINE:-unset} now=$(date +%s)"
exit "${FAKE_EXIT:-0}"
FAKE
chmod +x "$tmp/claude"
tick() { env FLEET_DASH_DIR="$D" SEATS_TABLE="$tmp/seats.tsv" MRC_TABLE="$tmp/mrc" GOAL_MD="$tmp/goal.md" APPROVALS_FILE="$tmp/approvals.log" SEAT_CLAUDE_BIN="$tmp/claude" \
         SEAT_OAUTH_ENV="$tmp/oauth.conf" SEAT_LOCK_WAIT=1 SEAT_ASK_LOCK_WAIT=1 "$@" "$TICK" tst; }
js() { jq -r "$1" "$D/tst-tick.json"; }
seed() { printf '{"ts":"2026-10-24T00:00:00-07:00","from":"t","text":"ask one"}\n{"ts":"2026-10-24T00:00:01-07:00","from":"t","text":"ask two"}\n' >"$D/tst-asks.pending"
         printf '2026-10-24T00:00:02-07:00 | t | event A\n2026-10-24T00:00:03-07:00 | t | event B\n' >>"$D/tst-events.log"; }
seed
t0="$(date +%s)"
FAKE_EXIT=7 tick >"$tmp/o7" 2>"$tmp/e7"; rc=$?
[ "$rc" = 7 ] && [ "$(wc -l <"$D/tst-asks.pending")" = 2 ] && [ "$(js .events_offset)" = 0 ] && ok "control: exit 7 restores the 2 asks and keeps the events cursor at 0" || bad "control exit 7 (rc=$rc asks=$(wc -l <"$D/tst-asks.pending") off=$(js .events_offset))"
dv="$(sed -n 's/^deadline=\([0-9]*\) .*/\1/p' "$tmp/o7" | head -1)"
[ -n "$dv" ] && [ "$dv" -ge $(( t0 + 3420 - 900 - 5 )) ] && [ "$dv" -le $(( $(date +%s) + 3420 - 900 )) ] && ok "claude sees SEAT_TURN_DEADLINE = start + 3420 - 900 ($dv)" || bad "deadline in claude env: '$dv'"
evsz="$(stat -c %s "$D/tst-events.log")"
FAKE_EXIT=124 tick >"$tmp/o124" 2>"$tmp/e124"; rc=$?
[ "$rc" = 124 ] && ok "exit 124 propagates (the unit still fails -> OnFailure)" || bad "rc=$rc"
# 124 #1: the 2 carried asks stay queued with carried:1 (the turn may never have read them), nothing dead-lettered
[ "$(wc -l <"$D/tst-asks.pending")" = 2 ] && [ "$(jq -s '[.[].carried]|unique' -c "$D/tst-asks.pending")" = "[1]" ] && [ ! -s "$D/tst-asks.dead" ] && ok "124 #1: 2 asks re-queued with carried:1, asks.dead empty" || bad "124 #1 carry: $(cat "$D/tst-asks.pending" "$D/tst-asks.dead" 2>&1 | head -c 300)"
[ "$(js .events_offset)" = "$evsz" ] && ok "124: events cursor advanced to the prompt's events ($evsz)" || bad "124 cursor $(js .events_offset) != $evsz"
[ "$(js .cap_kills)" = 1 ] && [ "$(js .cap_s)" = 3420 ] && [ "$(js .last_exit)" = 124 ] && [ "$(js .last_cap_kill)" != null ] && ok "124: cap_kills=1 cap_s=3420 last_exit=124 last_cap_kill set" || bad "124 state: $(jq -c '[.cap_kills,.cap_s,.last_exit,.last_cap_kill]' "$D/tst-tick.json")"
grep -q 'CAP-KILL #1' "$tmp/e124" && ok "124: CAP-KILL line logged" || bad "no CAP-KILL line"
# 124 #2: the same 2 asks carried a second time move to tst-asks.dead, one ALARM per ask in the events log
FAKE_EXIT=124 tick >"$tmp/o124b" 2>"$tmp/e124b"
[ "$(js .cap_kills)" = 2 ] && ok "second 124: cap_kills=2" || bad "cap_kills=$(js .cap_kills)"
[ ! -s "$D/tst-asks.pending" ] && [ "$(wc -l <"$D/tst-asks.dead")" = 2 ] && [ "$(jq -s '[.[].carried]|unique' -c "$D/tst-asks.dead")" = "[2]" ] && ok "124 #2: both asks moved to tst-asks.dead with carried:2, queue empty" || bad "124 #2 dead: pending=$(wc -l <"$D/tst-asks.pending") dead=$(cat "$D/tst-asks.dead" 2>&1 | head -c 300)"
[ "$(grep -c ' | asks-dead | ALARM asks-dead seat=tst n=[12]$' "$D/tst-events.log")" = 2 ] && grep -q 'ALARM asks-dead seat=tst n=2' "$D/tst-events.log" && ok "124 #2: 2 'ALARM asks-dead seat=tst n=<k>' lines in tst-events.log" || bad "asks-dead ALARM lines: $(grep asks-dead "$D/tst-events.log")"
FAKE_EXIT=0 tick >/dev/null 2>&1; [ "$(js .cap_kills)" = 0 ] && [ "$(js .cap_s)" = 3420 ] && ok "exit 0 resets cap_kills to 0" || bad "reset: $(js .cap_kills)"
# 137 (SIGKILL after timeout -k) = CAP-KILL with the same carried-ask handling
rm -f "$D/tst-asks.dead"; seed
FAKE_EXIT=137 tick >"$tmp/o137" 2>"$tmp/e137"; rc=$?
[ "$rc" = 137 ] && [ "$(js .cap_kills)" = 1 ] && [ "$(js .cap_s)" = 3420 ] && [ "$(js .last_exit)" = 137 ] && [ "$(js .last_cap_kill)" != null ] && grep -q 'CAP-KILL #1' "$tmp/e137" && ok "137: counted as CAP-KILL (cap_kills=1, last_cap_kill set, CAP-KILL line)" || bad "137 state rc=$rc: $(jq -c '[.cap_kills,.cap_s,.last_exit,.last_cap_kill]' "$D/tst-tick.json")"
[ "$(jq -s '[.[].carried]|unique' -c "$D/tst-asks.pending")" = "[1]" ] && ok "137: carried asks re-queued with carried:1" || bad "137 asks: $(cat "$D/tst-asks.pending")"
FAKE_EXIT=137 tick >/dev/null 2>&1; [ "$(wc -l <"$D/tst-asks.dead")" = 2 ] && ok "second 137: asks dead-lettered" || bad "137 dead: $(wc -l <"$D/tst-asks.dead" 2>&1)"

[ "$fail" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
