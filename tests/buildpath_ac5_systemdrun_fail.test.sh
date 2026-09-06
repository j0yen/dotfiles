#!/usr/bin/env bash
# tests/buildpath_ac5_systemdrun_fail.test.sh —
# PRD-build-path-unit-overlap-exit0 AC5: given a fake systemd-run that
# exits 1 with "Unit claude-build-work.service was already loaded or has
# a fragment file", the launcher exits 0 and logs
# "skip: systemd-run failed: Unit claude-build-work.service was already
# loaded or has a fragment file".
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=buildpath_test_helpers.sh
. "$here/buildpath_test_helpers.sh"

buildpath_setup
set_unit_state not-found "" ""
export FAKE_SYSTEMD_RUN_MODE=fail
export FAKE_SYSTEMD_RUN_FAIL_MSG="Unit claude-build-work.service was already loaded or has a fragment file"

bash "$LAUNCHER"
rc=$?

assert_eq "$rc" "0" "launcher exits 0 when systemd-run fails"
assert_contains "$(cat "$log")" "skip: systemd-run failed: Unit claude-build-work.service was already loaded or has a fragment file" "log line: systemd-run failure reason"

exit $fail
