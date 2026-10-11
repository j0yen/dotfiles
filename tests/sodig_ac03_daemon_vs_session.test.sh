#!/usr/bin/env bash
# PRD dotfiles-sibling-overlap-digest AC3: a daemon claim (run=516) and a
# session edit of the same PRD 10 minutes later -> the OVERLAP line names
# `daemon run=516` and the session id.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/sodig_test_helpers.sh"
sodig_setup

fx_commit 20 "chore: claim x (run=516)" x
ts=$(( $(date +%s) - 10 * 60 ))
mkdir -p "$OVERLAP_SESSIONS_DIR"
jq -nc --argjson ts "$ts" --arg p "$PRD_DIR/build-queue/PRD-x.md" \
  '{type:"agent.activity",ts:$ts,agent:"claude",status:"editing",summary:"edit x",paths:[$p]}' \
  >"$OVERLAP_SESSIONS_DIR/claude-2576670.ndjson"

run_digest --since 1h
line=$(grep '^OVERLAP:' <<<"$digest")
assert_contains "$line" "daemon run=516" "names the daemon run"
assert_contains "$line" "claude-2576670" "names the session id"
assert_contains "$line" "10 min" "names the gap"
assert_eq "$(tail -1 <<<"$digest")" "overlaps: 1" "overlaps: 1"
exit $fail
