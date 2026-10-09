#!/usr/bin/env bash
# PRD agorabus-overlap-warning-hook AC1: a peer sharing our skill (/dream)
# yields exactly one PEER OVERLAP line naming the peer, /dream and its prd.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/agorabus-overlap-warning-hook_test_helpers.sh"
overlap_setup
cat >"$FAKE_INTENT_JSON" <<JSON
[{"session_id":"claude-self","skill":"/dream","prd":"x","working_paths":["$cwd"]},
 {"session_id":"claude-peer","skill":"/dream","prd":"y","working_paths":["/elsewhere"]},
 {"session_id":"claude-idle","skill":"claude","prd":"","working_paths":["/elsewhere"]}]
JSON
out=$(run_hook)
assert_eq "$(printf '%s\n' "$out" | grep -c '^PEER OVERLAP:')" "1" "exactly one overlap line"
assert_contains "$out" "claude-peer" "names the peer"
assert_contains "$out" "/dream" "names the skill"
assert_contains "$out" "(y)" "names the peer's prd"
case "$out" in *claude-idle*) echo "NOT OK - idle peer flagged"; fail=1 ;; *) echo "ok - idle peer not flagged" ;; esac
exit $fail
