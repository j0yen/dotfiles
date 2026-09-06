#!/usr/bin/env bash
# tests/buildpath_ac4_notfound.test.sh — PRD-build-path-unit-overlap-exit0
# AC4: given LoadState=not-found, systemd-run --user --unit=claude-build-work
# is invoked once with the same arguments as before this change.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=buildpath_test_helpers.sh
. "$here/buildpath_test_helpers.sh"

buildpath_setup
set_unit_state not-found "" ""

bash "$LAUNCHER"
rc=$?

assert_eq "$rc" "0" "launcher exits 0 on a clean launch"
nruns="$(wc -l < "$systemd_run_calls")"
assert_eq "$nruns" "1" "systemd-run invoked exactly once"
call="$(cat "$systemd_run_calls")"
assert_contains "$call" "--user --unit=claude-build-work" "systemd-run called with --user --unit=claude-build-work"
assert_contains "$call" "--collect" "systemd-run called with --collect"
assert_contains "$(cat "$log")" "starting tick" "log line: starting tick"

exit $fail
