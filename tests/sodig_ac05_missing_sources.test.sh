#!/usr/bin/env bash
# PRD dotfiles-sibling-overlap-digest AC5: no sessions dir and no state.db ->
# exit 0, the header lists the missing sources, git rows are still produced.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/sodig_test_helpers.sh"
sodig_setup

fx_commit 10 "chore: claim x (run=516)" x
run_digest --since 1h
header=$(grep '^# ' <<<"$digest")
assert_eq "$rc" "0" "exit 0"
assert_contains "$header" "sessions missing" "header lists the missing sessions dir"
assert_contains "$header" "state.db missing" "header lists the missing state.db"
assert_contains "$digest" "| daemon run=516 | x | claim" "git row still produced"
assert_eq "$(tail -1 <<<"$digest")" "overlaps: 0" "overlaps line present"
exit $fail
