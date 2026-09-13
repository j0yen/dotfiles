#!/usr/bin/env bash
# tests/explorefirst_ac2_skip_this_week.test.sh — PRD-mcphost-explore-first-light
# AC2: given a pack already exists for the current ISO week, when the
# runner fires, then it exits 0 with `skip: this week ran` and starts no
# instance.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=explorefirst_test_helpers.sh
. "$here/explorefirst_test_helpers.sh"

explorefirst_setup

# First run lands this week's pack.
"$RUNNER" >/dev/null
: > "$mcphost_calls"   # reset the call log so the second run's check is clean
: > "$synthorg_calls"

out="$("$RUNNER")"
rc=$?

assert_eq "$rc" "0" "second fire in the same week exits 0"
assert_eq "$out" "skip: this week ran" "second fire prints the exact skip message"
assert_eq "$(wc -l < "$mcphost_calls")" "0" "no mcphost invocation on a skipped week (no instance started)"
assert_eq "$(wc -l < "$synthorg_calls")" "0" "no synthorg invocation on a skipped week"

exit "$fail"
