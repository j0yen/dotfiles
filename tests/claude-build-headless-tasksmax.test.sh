#!/usr/bin/env bash
# tests/claude-build-headless-tasksmax.test.sh — A1483: the transient claude-build-work unit
# passes -p TasksMax=infinity (a transient unit otherwise inherits the user slice's TasksMax).
# Uses the buildpath fake systemd-run, which records its argv.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=buildpath_test_helpers.sh
. "$here/buildpath_test_helpers.sh"

buildpath_setup
set_unit_state not-found inactive dead
bash "$LAUNCHER"
rc=$?
assert_eq "$rc" "0" "launcher exits 0"
calls="$(cat "$systemd_run_calls")"
assert_contains "$calls" "--unit=claude-build-work" "systemd-run was invoked for claude-build-work"
assert_contains "$calls" "-p TasksMax=infinity" "launch argv carries -p TasksMax=infinity"
exit $fail
