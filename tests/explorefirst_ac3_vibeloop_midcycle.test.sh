#!/usr/bin/env bash
# tests/explorefirst_ac3_vibeloop_midcycle.test.sh — PRD-mcphost-explore-first-light
# AC3: given the vibeloop measure is mid-cycle (its running marker
# present), when the runner fires, then it defers with a named skip and no
# instance starts.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=explorefirst_test_helpers.sh
. "$here/explorefirst_test_helpers.sh"

explorefirst_setup
export FAKE_SYSTEMCTL_ACTIVE_UNIT="claude-vibeloop-work.service"

out="$("$RUNNER")"
rc=$?

assert_eq "$rc" "0" "mid-cycle fire exits 0 (a defer, not a failure)"
assert_eq "$out" "skip: vibeloop mid-cycle" "mid-cycle fire names the skip"
assert_eq "$(wc -l < "$mcphost_calls")" "0" "no instance started while vibeloop is mid-cycle"
assert_contains "$(cat "$log_file")" "skip: vibeloop measure mid-cycle" "journal names the mid-cycle skip, checked not assumed"

exit "$fail"
