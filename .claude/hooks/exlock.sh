#!/usr/bin/env bash
# exlock.sh (A1296 package 2 repair 7, rv7 F7-4): THE one lock-file protocol of the advisory hooks (owed-now.sh refresh, summa-lookup-inject.sh --refresh-index). Sourced.
# A lock is a file created exclusively (bash noclobber = O_EXCL, never `mkdir`: uutils mkdir lets two racing callers both succeed, rv6 F6-4) that holds its owner's token.
#   exlock_take <path>  : 0 = held (EXLOCK_PATH / EXLOCK_TOKEN set), 1 = busy (another holder, or a stale lock another caller is replacing now). Never waits.
#   exlock_release      : removes the lock only while it still holds OUR token, so a holder that outlived the 5-minute staleness (and was replaced) never deletes its successor's lock.
# A lock older than 5 minutes is stale (SIGKILL / host death cannot run a trap). Replacing a stale lock is serialized by flock(1) on a sidecar file (<path>.reaper: the kernel
# releases it at process death, so the sidecar itself is never stale) and the staleness is re-read UNDER that flock: two callers can no longer both judge the same stale lock
# and both replace it (the old check / rm / create window, F7-4). Callers release on signals with: trap 'exlock_release' EXIT; trap 'exit 143' TERM; trap 'exit 130' INT; trap 'exit 129' HUP
# (set in the script's main flow, not inside a function or a $(...) subshell: a RETURN trap is inherited by command substitutions and released the lock early, rv6).
# Residual (named): a holder that legitimately runs past 5 minutes can lose its lock to a replacer, and a replacer's rm can coincide with that holder's own release; both need
# a lock older than the staleness bound.
EXLOCK_PATH=""; EXLOCK_TOKEN=""
exlock_stale() { [ -n "$(find "$1" -maxdepth 0 -mmin +5 2>/dev/null)" ]; }
exlock_take() {
  local l="$1" tok
  tok="$$.$RANDOM.$(date +%s%N 2>/dev/null)"
  if ( set -C; printf '%s' "$tok" >"$l" ) 2>/dev/null; then EXLOCK_PATH="$l"; EXLOCK_TOKEN="$tok"; return 0; fi
  exlock_stale "$l" || return 1
  command -v flock >/dev/null 2>&1 || return 1
  ( flock -n 9 || exit 1
    exlock_stale "$l" || exit 1
    rm -f "$l"; set -C; printf '%s' "$tok" >"$l" ) 9>>"$l.reaper" 2>/dev/null || return 1
  EXLOCK_PATH="$l"; EXLOCK_TOKEN="$tok"; return 0
}
exlock_release() {
  [ -n "${EXLOCK_PATH:-}" ] || return 0
  [ "$(cat "$EXLOCK_PATH" 2>/dev/null)" != "${EXLOCK_TOKEN:-}" ] || rm -f "$EXLOCK_PATH" 2>/dev/null
  EXLOCK_PATH=""; return 0
}
