#!/usr/bin/env bash
# tests/buildpath_test_helpers.sh — shared setup for tests/buildpath_ac*.test.sh
# (PRD-build-path-unit-overlap-exit0). Not itself a test file (no ac<N> in
# the name), sourced by every buildpath_ac*.test.sh. Puts a fake
# `systemctl`, `systemd-run`, and `agorabus` on PATH ahead of the real
# ones, and points the launcher/status script at a throwaway state dir,
# log, cgroup tree, and /proc via their CLAUDE_BUILD_* env hooks, so tests
# never touch the real system, run no network call, and run offline in
# well under the suite's 10s budget.
set -uo pipefail

LAUNCHER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.local/bin/claude-build-headless.sh"
STATUS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.local/bin/claude-build-status"
FIXTURES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures"

fail=0
assert_eq() { # $1=actual $2=expected $3=description
  if [ "$1" = "$2" ]; then echo "ok - $3"
  else echo "NOT OK - $3: got '$1', want '$2'"; fail=1; fi
}
assert_contains() { # $1=haystack $2=needle $3=description
  case "$1" in *"$2"*) echo "ok - $3" ;; *) echo "NOT OK - $3: '$1' does not contain '$2'"; fail=1 ;; esac
}
assert_file_missing_or_empty() { # $1=path $2=description
  if [ ! -s "$1" ]; then echo "ok - $2"
  else echo "NOT OK - $2: $1 has content: $(cat "$1")"; fail=1; fi
}

# buildpath_setup — creates $work (cleaned up on EXIT), a fake bin dir on
# PATH ahead of the real systemctl/systemd-run, a fresh state/log/cgroup
# tree, and exports every CLAUDE_BUILD_* hook the launcher reads.
buildpath_setup() {
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT

  bin="$work/bin"
  mkdir -p "$bin"
  ln -s "$FIXTURES/fake-systemctl" "$bin/systemctl"
  ln -s "$FIXTURES/fake-systemd-run" "$bin/systemd-run"
  ln -s "$FIXTURES/fake-agorabus" "$bin/agorabus"

  state_dir="$work/state"
  mkdir -p "$state_dir"
  log="$work/build-auto.log"
  cgroot="$work/cgroup"
  mkdir -p "$cgroot"
  proc_root="$work/proc"
  mkdir -p "$proc_root"

  systemctl_state="$work/systemctl-state"
  : > "$systemctl_state"
  systemctl_calls="$work/systemctl-calls"
  : > "$systemctl_calls"
  systemd_run_calls="$work/systemd-run-calls"
  : > "$systemd_run_calls"
  agorabus_calls="$work/agorabus-calls"
  : > "$agorabus_calls"

  export FAKE_SYSTEMCTL_STATE="$systemctl_state"
  export FAKE_SYSTEMCTL_CALLS="$systemctl_calls"
  export FAKE_SYSTEMD_RUN_CALLS="$systemd_run_calls"
  export FAKE_AGORABUS_CALLS="$agorabus_calls"
  unset FAKE_SYSTEMCTL_FREE_ON_RESET FAKE_SYSTEMD_RUN_MODE FAKE_SYSTEMD_RUN_FAIL_MSG

  export CLAUDE_BUILD_STATE="$state_dir"
  export CLAUDE_BUILD_LOG="$log"
  export CLAUDE_BUILD_CGROOT="$cgroot"
  export CLAUDE_BUILD_PROC_ROOT="$proc_root"

  export PATH="$bin:$PATH"
}

set_unit_state() { # LoadState ActiveState SubState
  printf 'LoadState=%s\nActiveState=%s\nSubState=%s\n' "$1" "$2" "$3" > "$systemctl_state"
}
