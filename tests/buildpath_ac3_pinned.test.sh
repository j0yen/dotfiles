#!/usr/bin/env bash
# tests/buildpath_ac3_pinned.test.sh — PRD-build-path-unit-overlap-exit0
# AC3: given LoadState=loaded, SubState=dead, a fake that still reports
# loaded after the reset, and a cgroup file listing pids 4242 and 4243,
# the launcher exits 0, logs the pinned pids with their command names, and
# systemd-run is not invoked.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=buildpath_test_helpers.sh
. "$here/buildpath_test_helpers.sh"

buildpath_setup
set_unit_state loaded dead dead
# FAKE_SYSTEMCTL_FREE_ON_RESET intentionally unset: reset-failed does not
# free the unit (cgroup still pinned).
cgpath="/user.slice/test.slice/claude-build-work.service"
{ printf 'LoadState=loaded\nActiveState=inactive\nSubState=dead\nControlGroup=%s\n' "$cgpath"; } > "$systemctl_state"
mkdir -p "$cgroot$cgpath"
printf '4242\n4243\n' > "$cgroot$cgpath/cgroup.procs"
mkdir -p "$proc_root/4242" "$proc_root/4243"
printf 'claude-tick\n' > "$proc_root/4242/comm"
printf 'claude-tracer\n' > "$proc_root/4243/comm"

bash "$LAUNCHER"
rc=$?

assert_eq "$rc" "0" "launcher exits 0 when work unit is pinned"
logtext="$(cat "$log")"
assert_contains "$logtext" "skip: work unit pinned by pids 4242 4243" "log line: pinned pids"
assert_contains "$logtext" "claude-tick" "log line: names comm 4242"
assert_contains "$logtext" "claude-tracer" "log line: names comm 4243"
calls="$(cat "$systemctl_calls")"
assert_eq "$calls" "$(printf 'stop\nreset-failed')" "stop then reset-failed, in order"
assert_file_missing_or_empty "$systemd_run_calls" "systemd-run was not invoked"

exit $fail
