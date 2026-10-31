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
# operator-notices.sh and model-role-check.sh were appended after this PRD; the latter
# is wired as an `sh -c '[ -x \"$HOME/.claude/hooks/model-role-check.sh\" ] && exec ...; exit 0'`
# guard, so the basename strip above leaves its tail (model-role-check.sh\"; exit 0'\").
mrc="model-role-check.sh\\\"; exit 0'\""
# aide-inbox.sh (10-23, the aide inbox) is also appended after this PRD, as the last entry; it is excluded here and checked by tests/aide-inbox.test.sh.
# skill-marker.sh + analysis-skill-router.sh (10-24) likewise; checked by tests/analysis-page-gate.test.sh + tests/analysis-skill-router.test.sh.
assert_eq "$(jq -c "$ups | map(select(. != \"agorabus-overlap.sh\" and . != \"skill-marker.sh\" and . != \"analysis-skill-router.sh\" and (startswith(\"aide-inbox.sh\") | not)))" "$S")" \
  '["peon.sh","hook-handle-use.sh","hook-handle-rename.sh","recall-user-prompt.sh","recall-search-inject.sh","summa-lookup-inject.sh","dream-marker.sh","agorabus-intent.sh","operator-notices.sh","'"$mrc"']' \
  "existing UserPromptSubmit hooks unchanged"
assert_eq "$(jq -r '[.hooks.UserPromptSubmit[] | select(.hooks[0].command | test("aide-inbox[.]sh") | not)][-1].hooks[0] | "\(.type) \(.timeout)"' "$S")" "command 5" "entry shape matches sibling hooks"
exit $fail
