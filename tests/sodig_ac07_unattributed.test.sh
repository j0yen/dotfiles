#!/usr/bin/env bash
# PRD dotfiles-sibling-overlap-digest AC7: a park: commit with no run= and no
# activity event gets actor `session?` and the header reads `unattributed: 1`.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/sodig_test_helpers.sh"
sodig_setup

fx_commit 10 "park: x (waiting)" x
fx_activity session-A "unrelated work"      # sessions dir exists but names no commit
run_digest --since 1h
assert_contains "$digest" "| session? | x | park" "row actor is session?"
assert_contains "$(grep '^# ' <<<"$digest")" "unattributed: 1" "header reads unattributed: 1"
exit $fail
