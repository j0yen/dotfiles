#!/usr/bin/env bash
# PRD agorabus-intent-auto-from-skill AC3: Stop after a skill start resets
# intent to `claude` and publishes `finished` naming the skill; Stop with no
# skill this turn records nothing.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/agorabus-intent-auto-from-skill_test_helpers.sh"
intent_setup

stop_json=$(jq -cn --arg c "$cwd" '{hook_event_name:"Stop",cwd:$c}')
run_hook "$stop_json" stop
assert_eq "$(cat "$calls")" "" "Stop with no skill records nothing"

run_hook "$(jq -cn --arg c "$cwd" '{hook_event_name:"PreToolUse",cwd:$c,tool_input:{skill:"dream",args:"x"}}')"
: >"$calls"
run_hook "$stop_json" stop
assert_contains "$(cat "$calls")" "intent set --session-id $sid --skill claude --prd " "intent reset to claude"
publine=$(grep "^publish " "$calls")
payload=${publine#publish --session-id $sid agent.activity }
assert_eq "$(printf '%s' "$payload" | jq -r .status)" "finished" "status finished"
assert_eq "$(printf '%s' "$payload" | jq -r .summary)" "/dream" "names /dream"

: >"$calls"
run_hook "$stop_json" stop
assert_eq "$(cat "$calls")" "" "second Stop records nothing"
exit $fail
