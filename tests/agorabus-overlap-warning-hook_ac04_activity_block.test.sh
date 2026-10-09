#!/usr/bin/env bash
# PRD agorabus-overlap-warning-hook AC4: three peer events inside 2 h (plus a
# 3 h old one, our own event and a non-activity topic) → first run prints
# PEER ACTIVITY (2h): with exactly three lines, second run prints nothing.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/agorabus-overlap-warning-hook_test_helpers.sh"
overlap_setup
now=$(date +%s)
ev() { # $1=age seconds $2=sid $3=topic $4=status $5=summary
  printf '{"ts":"%s","topic":"%s","session_id":"%s","data":{"agent":"claude","status":"%s","summary":"%s"}}\n' \
    "$(date -u -d "@$(( now - $1 ))" +%Y-%m-%dT%H:%M:%S.123456Z)" "$3" "$2" "$4" "$5"
}
{ ev 60 claude-a agent.activity started "/dream x"
  ev 600 claude-b agent.activity finished "/build y"
  ev 3000 claude-c agent.activity started "/loop z"
  ev 10800 claude-d agent.activity started "three hours old"
  ev 30 claude-self agent.activity started "our own"
  ev 30 claude-a chat.msg hello "not activity"; } >"$AGORABUS_INTENT_STATE_DIR/sessions/$sid.ndjson"
first=$(run_hook)
assert_eq "$(printf '%s\n' "$first" | head -n1)" "PEER ACTIVITY (2h):" "header"
assert_eq "$(printf '%s\n' "$first" | tail -n +2 | grep -c .)" "3" "exactly three event lines"
assert_contains "$first" "claude-a started /dream x" "line format sid status summary"
case "$first" in *claude-d*|*"our own"*|*"not activity"*) echo "NOT OK - stale/own/other-topic event shown"; fail=1 ;; *) echo "ok - stale, own and other-topic events excluded" ;; esac
assert_eq "$(printf '%s\n' "$first" | sed -n 2p | grep -cE '^([1-9]|1[0-2]):[0-9]{2} [AP]M ')" "1" "12-hour am/pm time"
assert_eq "$(run_hook)" "" "second run prints nothing"
ev 5 claude-e agent.activity started "new one" >>"$AGORABUS_INTENT_STATE_DIR/sessions/$sid.ndjson"
assert_contains "$(run_hook)" "claude-e started new one" "changed set prints again"
exit $fail
