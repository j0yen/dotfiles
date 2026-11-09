#!/usr/bin/env bash
# PRD agorabus-intent-auto-from-skill AC2: a typed `/self-review` prompt sets
# intent with an empty prd; a prompt that merely mentions `/dream` sets nothing.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/agorabus-intent-auto-from-skill_test_helpers.sh"
intent_setup

run_hook "$(jq -cn --arg c "$cwd" '{hook_event_name:"UserPromptSubmit",cwd:$c,prompt:"/self-review"}')"
assert_contains "$(cat "$calls")" "intent set --session-id $sid --skill /self-review --prd  --paths $cwd" "typed prompt sets intent, empty prd"

: >"$calls"
run_hook "$(jq -cn --arg c "$cwd" '{hook_event_name:"UserPromptSubmit",cwd:$c,prompt:"please /dream later"}')"
assert_eq "$(cat "$calls")" "" "mid-sentence /dream sets nothing"

: >"$calls"
run_hook "$(jq -cn --arg c "$cwd" '{hook_event_name:"UserPromptSubmit",cwd:$c,prompt:"  /dream mcphost oauth"}')"
assert_contains "$(cat "$calls")" "--skill /dream --prd mcphost-oauth" "leading whitespace + args"
exit $fail
