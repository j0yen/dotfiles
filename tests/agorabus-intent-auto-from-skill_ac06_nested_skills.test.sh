#!/usr/bin/env bash
# PRD agorabus-intent-auto-from-skill AC6: `/dream a` then the Skill tool
# `write` in one turn — intent is last set to /write, and Stop resets once.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/agorabus-intent-auto-from-skill_test_helpers.sh"
intent_setup

run_hook "$(jq -cn --arg c "$cwd" '{hook_event_name:"UserPromptSubmit",cwd:$c,prompt:"/dream a"}')"
run_hook "$(jq -cn --arg c "$cwd" '{hook_event_name:"PreToolUse",cwd:$c,tool_input:{skill:"write"}}')"
run_hook "$(jq -cn --arg c "$cwd" '{hook_event_name:"Stop",cwd:$c}')" stop

sets=$(grep '^intent set ' "$calls")
nreset=$(grep -c -- '--skill claude --prd ' <<<"$sets")
assert_eq "$nreset" "1" "exactly one reset"
last_before_reset=$(grep -B1 -- '--skill claude' <<<"$sets" | head -n1)
assert_contains "$last_before_reset" "--skill /write " "intent last set to /write before the reset"
assert_eq "$(grep -c -- '--skill /dream' <<<"$sets")" "1" "dream start recorded once"
assert_eq "$(tail -n1 <<<"$sets" | grep -c -- '--skill claude')" "1" "reset is the final intent call"
fin=$(grep '"status":"finished"' "$calls")
assert_contains "$fin" '"summary":"/write"' "finished names the last skill"
assert_eq "$(grep -c '"status":"finished"' "$calls")" "1" "exactly one finished publish"
exit $fail
