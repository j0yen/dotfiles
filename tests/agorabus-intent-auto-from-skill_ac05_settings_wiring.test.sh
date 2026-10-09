#!/usr/bin/env bash
# PRD agorabus-intent-auto-from-skill AC5: settings.json wires the script once
# under UserPromptSubmit, PreToolUse (matcher Skill) and Stop; dream-marker.sh
# entries are untouched.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/agorabus-intent-auto-from-skill_test_helpers.sh"
S="$ROOT/.claude/settings.json"
jq -e . "$S" >/dev/null || { echo "NOT OK - settings.json parses"; exit 1; }

count() { # $1=event $2=matcher-filter(jq bool expr over the group)
  jq -r "[.hooks.$1[] | select($2) | .hooks[].command | select(test(\"agorabus-intent\\\\.sh\"))] | length" "$S"
}
assert_eq "$(count UserPromptSubmit true)" "1" "UserPromptSubmit: once"
assert_eq "$(count PreToolUse '.matcher=="Skill"')" "1" "PreToolUse Skill: once"
assert_eq "$(count PreToolUse '.matcher!="Skill"')" "0" "PreToolUse other matchers: none"
assert_eq "$(count Stop true)" "1" "Stop: once"
assert_eq "$(jq -r '[.hooks.Stop[].hooks[].command | select(test("agorabus-intent\\.sh stop$"))] | length' "$S")" "1" "Stop passes the stop arg"
total=$(jq -r '[.hooks[][].hooks[].command | select(test("agorabus-intent\\.sh"))] | length' "$S")
assert_eq "$total" "3" "script appears exactly three times overall"

# dream-marker.sh: one UserPromptSubmit entry and one PreToolUse Skill entry, as before.
assert_eq "$(jq -r '[.hooks.UserPromptSubmit[].hooks[].command | select(test("dream-marker\\.sh"))] | length' "$S")" "1" "dream-marker UserPromptSubmit unchanged"
assert_eq "$(jq -r '[.hooks.PreToolUse[] | select(.matcher=="Skill") | .hooks[].command | select(test("dream-marker\\.sh"))] | length' "$S")" "1" "dream-marker PreToolUse Skill unchanged"
# Order: dream-marker keeps its slot ahead of the new hook in the Skill group.
assert_eq "$(jq -r '[.hooks.PreToolUse[] | select(.matcher=="Skill") | .hooks[].command | select(test("dream-marker|agorabus-intent")) | sub(".*/";"")] | join(",")' "$S")" "dream-marker.sh,agorabus-intent.sh" "dream-marker precedes in Skill group"
exit $fail
