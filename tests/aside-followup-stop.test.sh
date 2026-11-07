#!/usr/bin/env bash
# aside-followup-stop.sh: unrowed aside refused; rowed, done-claimed, closed-row, loop-guard cases.
set -u
H="$(dirname "$0")/../.claude/hooks/aside-followup-stop.sh"; S="$(dirname "$0")/../.claude/settings.json"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export ASIDE_STOP_LOG="$T/fires.log" ASIDE_OPEN_ASKS="$T/open-asks.tsv"
fail=0
printf '# header\nA1\topen row about rb-seat-tick.timer due Sun\n# CLOSED\nA2\tclosed row about old-thing.service\n' >"$ASIDE_OPEN_ASKS"
run(){ jq -nc --arg m "$1" --argjson a "${2:-false}" '{last_assistant_message:$m,stop_hook_active:$a,session_id:"s"}' | WM_SEAT=rb "$H"; }
blocks(){ printf '%s' "$1" | jq -e '.decision=="block"' >/dev/null 2>&1; }
t(){ # name want(block|allow) msg [active]
  out=$(run "$3" "${4:-false}")
  if [ "$2" = block ]; then blocks "$out" && echo "ok $1" || { echo "FAIL $1: '$out'"; fail=1; }
  else [ -z "$out" ] && echo "ok $1" || { echo "FAIL $1: '$out'"; fail=1; }; fi
}
# handover 2.7: scoped to WM_SEAT sessions; empty WM_SEAT is silent, no log line
before=$(wc -l <"$T/fires.log" 2>/dev/null || echo 0)
out=$(jq -nc '{last_assistant_message:"The rb timer is a separate check, not investigated.",stop_hook_active:false,session_id:"s"}' | env -u WM_SEAT "$H"); rc=$?
after=$(wc -l <"$T/fires.log" 2>/dev/null || echo 0)
[ -z "$out" ] && [ "$rc" = 0 ] && [ "$before" = "$after" ] && echo "ok plain session (WM_SEAT empty): silent exit 0" || { echo "FAIL plain session scoped: '$out'"; fail=1; }
t unrowed block "The rb timer is a separate check, not investigated."
echo "reason: $(run 'The rb timer is a separate check, not investigated.' | jq -r .reason)"
t rowed allow "The rb-seat-tick.timer is a separate check, not investigated."
t done allow "The rb timer was a separate check, checked and found normal."
t closed block "The old-thing.service is a separate check, not investigated."
t loopguard allow "The rb timer is a separate check, not investigated." true
t nophrase allow "All finished, tests pass."
t notdone block "That has not been done."
grep -q 'refuse' "$T/fires.log" && grep -q 'allow-after-match' "$T/fires.log" && echo "ok fires logged" || { echo "FAIL fires log"; fail=1; }
before=$(wc -l <"$T/fires.log")
out=$(printf 'not json{' | "$H"); rc=$?
[ -z "$out" ] && [ $rc = 0 ] && [ "$(wc -l <"$T/fires.log")" -gt "$before" ] && grep -q 'error allow' "$T/fires.log" && echo "ok malformed allow+log" || { echo "FAIL malformed"; fail=1; }
jq -e '.hooks.Stop[] | .hooks[] | select(.command|endswith("aside-followup-stop.sh"))' "$S" >/dev/null && echo "ok wired" || { echo "FAIL wired"; fail=1; }
exit $fail
