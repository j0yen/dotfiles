#!/usr/bin/env bash
# PRD agorabus-overlap-warning-hook AC7: settings.json wires agorabus-overlap.sh
# once under UserPromptSubmit, after agorabus-intent.sh, and nowhere else; the
# existing UserPromptSubmit hooks are still present in their original order.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/agorabus-overlap-warning-hook_test_helpers.sh"
S="$ROOT/.claude/settings.json"
jq -e . "$S" >/dev/null || { echo "NOT OK - settings.json parses"; exit 1; }

ups='[.hooks.UserPromptSubmit[].hooks[].command | sub(".*/";"")]'
assert_eq "$(jq -r "$ups | map(select(. == \"agorabus-overlap.sh\")) | length" "$S")" "1" "UserPromptSubmit: overlap hook once"
assert_eq "$(jq -r '[.hooks[][].hooks[].command | select(test("agorabus-overlap\\.sh"))] | length' "$S")" "1" "overlap hook appears once overall"
assert_eq "$(jq -r "$ups | (index(\"agorabus-overlap.sh\")) - (index(\"agorabus-intent.sh\"))" "$S")" "1" "directly after agorabus-intent.sh"
# Existing hooks unchanged: dropping our entry leaves the pre-change command list.
assert_eq "$(jq -c "$ups | map(select(. != \"agorabus-overlap.sh\"))" "$S")" \
  '["peon.sh","hook-handle-use.sh","hook-handle-rename.sh","recall-user-prompt.sh","recall-search-inject.sh","summa-lookup-inject.sh","dream-marker.sh","agorabus-intent.sh"]' \
  "existing UserPromptSubmit hooks unchanged"
assert_eq "$(jq -r '.hooks.UserPromptSubmit[-1].hooks[0] | "\(.type) \(.timeout)"' "$S")" "command 5" "entry shape matches sibling hooks"
exit $fail
