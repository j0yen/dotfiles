#!/usr/bin/env bash
# tests/buildpath_ac1_tick_running.test.sh — PRD-build-path-unit-overlap-exit0
# AC1: given a fake systemctl reporting ActiveState=active, the launcher
# exits 0, logs "skip: tick running", and systemd-run is not invoked.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=buildpath_test_helpers.sh
. "$here/buildpath_test_helpers.sh"

buildpath_setup
set_unit_state loaded active running

bash "$LAUNCHER"
rc=$?

assert_eq "$rc" "0" "launcher exits 0 when work unit is active"
assert_contains "$(cat "$log")" "skip: tick running" "log line: skip: tick running"
assert_file_missing_or_empty "$systemd_run_calls" "systemd-run was not invoked"

exit $fail
