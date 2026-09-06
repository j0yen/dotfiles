#!/usr/bin/env bash
# Launcher for the /build path unit: one PRD-tick per firing, never
# overlapping, and never a non-zero exit for a state the launcher itself
# can reason about (PRD-build-path-unit-overlap-exit0). Every reason a
# tick cannot start now — overlap, a dead-but-loaded work unit, a pinned
# cgroup, or a systemd-run race — is exit 0 with one logged reason. Only
# a genuine launch failure inside claude-build-tick.sh itself (not this
# launcher) can still surface as non-zero from the service.
#
# Test hooks (unset in production): CLAUDE_BUILD_STATE, CLAUDE_BUILD_LOG,
# CLAUDE_BUILD_WORK_UNIT, CLAUDE_BUILD_CGROOT, CLAUDE_BUILD_PROC_ROOT let
# tests point the launcher at a throwaway state dir, log, cgroup tree, and
# /proc without touching the real system. A fake `systemctl` / `systemd-run`
# earlier on PATH supplies the rest.
set -uo pipefail

STATE="${CLAUDE_BUILD_STATE:-$HOME/.claude/skills/build/state}"
LOG="${CLAUDE_BUILD_LOG:-$HOME/brain/journal/build-auto.log}"
WORK_UNIT="${CLAUDE_BUILD_WORK_UNIT:-claude-build-work.service}"
CGROOT="${CLAUDE_BUILD_CGROOT:-/sys/fs/cgroup}"
PROC_ROOT="${CLAUDE_BUILD_PROC_ROOT:-/proc}"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
logline() { echo "$(ts) launcher: $*" >> "$LOG"; }

[ -f "$STATE/paused" ] && { logline "paused (state/paused present)"; exit 0; }

# One call for all three states, in the order requested (PRD requirement:
# "one call").
states="$(systemctl --user show "$WORK_UNIT" -p LoadState -p ActiveState -p SubState --value 2>/dev/null)"
load_state="$(printf '%s\n' "$states" | sed -n '1p')"
active_state="$(printf '%s\n' "$states" | sed -n '2p')"
sub_state="$(printf '%s\n' "$states" | sed -n '3p')"

if [ "$active_state" = "active" ] || [ "$active_state" = "activating" ]; then
  logline "skip: tick running"
  exit 0
fi

if [ "$load_state" = "loaded" ] && [ "$sub_state" = "dead" ]; then
  systemctl --user stop "$WORK_UNIT" >/dev/null 2>&1
  systemctl --user reset-failed "$WORK_UNIT" >/dev/null 2>&1
  load_state="$(systemctl --user show "$WORK_UNIT" -p LoadState --value 2>/dev/null)"
  if [ "$load_state" = "not-found" ]; then
    logline "skip: work unit loaded (dead, freed)"
    # falls through to the launch below
  else
    cgpath="$(systemctl --user show "$WORK_UNIT" -p ControlGroup --value 2>/dev/null)"
    procs_file="$CGROOT${cgpath}/cgroup.procs"
    pids=""
    if [ -n "$cgpath" ] && [ -r "$procs_file" ]; then
      pids="$(tr '\n' ' ' < "$procs_file" | sed 's/[[:space:]]*$//')"
    fi
    if [ -n "$pids" ]; then
      names=""
      for pid in $pids; do
        comm="$(cat "$PROC_ROOT/$pid/comm" 2>/dev/null || echo unknown)"
        names="${names:+$names }$comm"
      done
      logline "skip: work unit pinned by pids $pids ($names each)"
    else
      logline "skip: work unit pinned (no pids found in cgroup)"
    fi
    exit 0
  fi
elif [ "$load_state" != "not-found" ]; then
  # Any other combination (e.g. still loaded but neither active/activating
  # nor dead) is unexpected; skip rather than race systemd-run against it.
  logline "skip: work unit in unexpected state (load=$load_state active=$active_state sub=$sub_state)"
  exit 0
fi

run_out="$(systemd-run --user --unit=claude-build-work --collect --quiet \
  -p RuntimeMaxSec=1800 -p WorkingDirectory="$HOME" \
  -p StandardOutput="append:$LOG" -p StandardError="append:$LOG" \
  --setenv=HOME="$HOME" --setenv=CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 --setenv=PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin" \
  "$HOME/.local/bin/claude-build-tick.sh" 2>&1)"
run_rc=$?

if [ "$run_rc" -ne 0 ]; then
  first_line="$(printf '%s\n' "$run_out" | head -1)"
  logline "skip: systemd-run failed: $first_line"
  exit 0
fi

logline "starting tick"
exit 0
