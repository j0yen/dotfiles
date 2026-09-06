#!/usr/bin/env bash
# tests/buildpath_ac2_freed.test.sh — PRD-build-path-unit-overlap-exit0 AC2:
# given LoadState=loaded, SubState=dead, and a fake that reports not-found
# after stop+reset-failed, the launcher calls stop then reset-failed (in
# that order), logs the freed line, launches, and systemd-run is invoked
# exactly once.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=buildpath_test_helpers.sh
. "$here/buildpath_test_helpers.sh"

buildpath_setup
set_unit_state loaded dead dead
export FAKE_SYSTEMCTL_FREE_ON_RESET=1

bash "$LAUNCHER"
rc=$?

assert_eq "$rc" "0" "launcher exits 0 on freed+launch"
calls="$(cat "$systemctl_calls")"
assert_eq "$calls" "$(printf 'stop\nreset-failed')" "stop then reset-failed, in order"
assert_contains "$(cat "$log")" "skip: work unit loaded (dead, freed)" "log line: freed"
assert_contains "$(cat "$log")" "starting tick" "log line: starting tick"
nruns="$(wc -l < "$systemd_run_calls")"
assert_eq "$nruns" "1" "systemd-run invoked exactly once"

exit $fail
