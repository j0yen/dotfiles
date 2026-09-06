#!/usr/bin/env bash
# tests/buildpath_ac10_pinned_bus_and_status.test.sh —
# PRD-build-path-unit-overlap-exit0 AC10 (P1): given a pinned cgroup, the
# launcher publishes one agent.activity bus event naming the pids, and
# `claude-build-status` prints the same pids.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=buildpath_test_helpers.sh
. "$here/buildpath_test_helpers.sh"

buildpath_setup
set_unit_state loaded dead dead
# FAKE_SYSTEMCTL_FREE_ON_RESET intentionally unset: the cgroup stays pinned
# after stop+reset-failed, same fixture shape as buildpath_ac3_pinned.
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

bus_calls="$(cat "$agorabus_calls")"
assert_contains "$bus_calls" "publish agent.activity" "bus: agent.activity topic published"
assert_contains "$bus_calls" "4242" "bus: payload names pid 4242"
assert_contains "$bus_calls" "4243" "bus: payload names pid 4243"
assert_contains "$bus_calls" "--session-id claude-activity" "bus: published under claude-activity session id"
bus_call_count="$(wc -l < "$agorabus_calls")"
assert_eq "$bus_call_count" "1" "exactly one bus event published"

status_out="$(bash "$STATUS")"
assert_contains "$status_out" "pinned pids: 4242 4243" "status: prints pinned pids"
assert_contains "$status_out" "claude-tick" "status: names comm 4242"
assert_contains "$status_out" "claude-tracer" "status: names comm 4243"

exit $fail
