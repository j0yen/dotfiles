#!/usr/bin/env bash
# PRD dotfiles-handoff-generated AC6: for a prose file with
# `max_runs 4, gate parallelism 1` and `cordon 157 holds plan-limits`,
# handoff-lint.sh prints two `restates` lines with the line numbers, exit 0.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/hgen_test_helpers.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
printf '%s\n' 'A trap: never restart in a gate window.' 'max_runs 4, gate parallelism 1' 'Joe said "stop wasting money".' 'cordon 157 holds plan-limits' >"$work/prose.md"
out="$("$LINT" "$work/prose.md")"; rc=$?
assert_eq "$rc" "0" "exits 0"
assert_eq "$(grep -c ' restates ' <<<"$out")" "2" "exactly two restates lines (line 2 once, line 4 once)"
assert_contains "$out" "line 2 restates effective_config max_runs" "line 2 max_runs"
assert_contains "$out" "line 4 restates decisions cordon" "line 4 cordon"
assert_eq "$(grep -c '^line [13] ' <<<"$out")" "0" "clean lines 1 and 3 not flagged"
printf '%s\n' 'run 659 stage land' 'wm-build 0.73.2 LIVE' 'decision 7 open' >"$work/p2.md"
assert_eq "$("$LINT" "$work/p2.md" | grep -c ' restates ')" "3" "other patterns: run stage, version live, decision open"
"$LINT" "$work/missing.md"; assert_eq "$?" "0" "missing file still exits 0"
exit $fail
