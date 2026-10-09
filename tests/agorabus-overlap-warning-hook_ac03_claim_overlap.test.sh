#!/usr/bin/env bash
# PRD agorabus-overlap-warning-hook AC3: another session's claim on a repo
# directory above our cwd yields an overlap line naming holder and reason; our
# own claim and a claim elsewhere print nothing.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/agorabus-overlap-warning-hook_test_helpers.sh"
overlap_setup
repo="$work/repo"; cwd="$repo/src"; mkdir -p "$cwd"
cat >"$FAKE_CLAIM_JSON" <<JSON
[{"session_id":"claude-holder","path":"$repo","reason":"refactoring the parser"},
 {"session_id":"claude-self","path":"$repo","reason":"mine"},
 {"session_id":"claude-far","path":"$work/other","reason":"elsewhere"}]
JSON
out=$(run_hook)
assert_eq "$(printf '%s\n' "$out" | grep -c '^PEER OVERLAP:')" "1" "exactly one overlap line"
assert_contains "$out" "claude-holder" "names the claim holder"
assert_contains "$out" "refactoring the parser" "names the claim reason"
case "$out" in *claude-far*|*mine*) echo "NOT OK - own/unrelated claim flagged"; fail=1 ;; *) echo "ok - own and unrelated claims silent" ;; esac
exit $fail
