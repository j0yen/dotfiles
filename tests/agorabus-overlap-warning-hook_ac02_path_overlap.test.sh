#!/usr/bin/env bash
# PRD agorabus-overlap-warning-hook AC2: a peer whose working path is a prefix
# of ours ($PRD_DIR, the PRD repo) prints one overlap line; a peer whose only
# path is $HOME prints nothing.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/agorabus-overlap-warning-hook_test_helpers.sh"
overlap_setup
PRD_DIR="$work/prds"; mkdir -p "$PRD_DIR/sub"
cwd="$PRD_DIR/sub"
cat >"$FAKE_INTENT_JSON" <<JSON
[{"session_id":"claude-self","skill":"claude","working_paths":["$cwd"]},
 {"session_id":"claude-repo","skill":"claude","working_paths":["$PRD_DIR"]},
 {"session_id":"claude-home","skill":"claude","working_paths":["$HOME"]},
 {"session_id":"claude-sibling","skill":"claude","working_paths":["$PRD_DIR/subway"]}]
JSON
out=$(run_hook)
assert_eq "$(printf '%s\n' "$out" | grep -c '^PEER OVERLAP:')" "1" "exactly one overlap line"
assert_contains "$out" "claude-repo" "repo-prefix peer flagged"
assert_contains "$out" "$PRD_DIR" "line carries the overlapping path"
case "$out" in *claude-home*|*claude-sibling*) echo "NOT OK - \$HOME/sibling-prefix peer flagged"; fail=1 ;; *) echo "ok - \$HOME and string-prefix-only peers silent" ;; esac
# We sit in $HOME ourselves: a peer in $HOME still prints nothing.
cwd="$HOME"
sed -i "s#\"claude-self\",\"skill\":\"claude\",\"working_paths\":\[\"[^\"]*\"\]#\"claude-self\",\"skill\":\"claude\",\"working_paths\":[\"$HOME\"]#" "$FAKE_INTENT_JSON"
assert_eq "$(run_hook | grep -c claude-home)" "0" "peer in \$HOME silent when we are in \$HOME"
exit $fail
