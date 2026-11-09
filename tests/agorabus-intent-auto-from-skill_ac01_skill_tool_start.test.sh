#!/usr/bin/env bash
# PRD agorabus-intent-auto-from-skill AC1: a Skill-tool PreToolUse for
# `dream` with args "mcphost oauth" sets intent and publishes `started`.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/agorabus-intent-auto-from-skill_test_helpers.sh"
intent_setup

json=$(jq -cn --arg c "$cwd" '{hook_event_name:"PreToolUse",tool_name:"Skill",cwd:$c,tool_input:{skill:"dream",args:"mcphost oauth"}}')
run_hook "$json"; rc=$?
assert_eq "$rc" "0" "hook exits 0"

assert_contains "$(cat "$calls")" "intent set --session-id $sid --skill /dream --prd mcphost-oauth --paths $cwd" "intent set recorded"
npub=$(grep -c "^publish --session-id $sid agent.activity " "$calls")
assert_eq "$npub" "1" "exactly one agent.activity publish"
publine=$(grep "^publish " "$calls")
payload=${publine#publish --session-id $sid agent.activity }
assert_eq "$(printf '%s' "$payload" | jq -r .status)" "started" "status started"
assert_eq "$(printf '%s' "$payload" | jq -r .summary)" "/dream mcphost-oauth" "summary"
exit $fail
