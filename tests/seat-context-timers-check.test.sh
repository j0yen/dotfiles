#!/usr/bin/env bash
# tests/seat-context-timers-check.test.sh -- seat-context-start.sh runs the start-trigger helper (aide path and rb/r7/ctl path): silent when healthy, prints a TIMERS block with the FAIL lines otherwise,
# silent when the helper is absent, never changes the hook's exit status. Helper is a stub in a throwaway HOME; no systemctl, no ssh.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"; HOOK="$root/.claude/hooks/seat-context-start.sh"
fail=0; chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
T="$(mktemp -d "${TMPDIR:-/tmp}/sctc.XXXXXX")"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/.local/bin"
stub() { printf '#!/bin/sh\necho "args: $*" >&2\n%s\n' "$1" >"$T/.local/bin/timers-start-trigger-live.sh"; chmod +x "$T/.local/bin/timers-start-trigger-live.sh"; }
run() { env -i PATH="$PATH" HOME="$T" TERM=dumb WM_SEAT="$1" TIMERS_CHECK_TIMEOUT=5 bash "$HOOK" </dev/null 2>/dev/null; }
for seat in aide rb; do
  stub 'exit 0'; out="$(run $seat)"; rc=$?
  [ "$rc" = 0 ] && ! printf '%s' "$out" | grep -q '=== TIMERS'; chk "$seat: healthy helper (no output): no TIMERS block, exit 0" $?
  stub 'echo "FAIL redbaron claude-vibeloop.timer no start trigger (has: OnUnitActiveUSec=3min)"; exit 1'; out="$(run $seat)"; rc=$?
  [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '^=== TIMERS: user timer(s) without a start trigger' && printf '%s' "$out" | grep -q '^FAIL redbaron claude-vibeloop.timer'; chk "$seat: FAIL line printed under a TIMERS header, hook still exits 0" $?
  stub 'sleep 30'; s=$(date +%s); out="$(run $seat)"; rc=$?
  [ "$rc" = 0 ] && [ $(( $(date +%s) - s )) -lt 20 ]; chk "$seat: a hung helper is cut by the timeout" $?
  rm -f "$T/.local/bin/timers-start-trigger-live.sh"; out="$(run $seat)"; rc=$?
  [ "$rc" = 0 ] && ! printf '%s' "$out" | grep -q '=== TIMERS'; chk "$seat: helper absent: silent, exit 0" $?
done
# the helper is invoked with all three hosts and --failures-only
printf '#!/bin/sh\necho "$*" >"%s/args"\n' "$T" >"$T/.local/bin/timers-start-trigger-live.sh"; chmod +x "$T/.local/bin/timers-start-trigger-live.sh"; run rb >/dev/null
[ "$(cat "$T/args" 2>/dev/null)" = '--failures-only --hosts carbon redbaron ryzen7' ]; chk "helper called with --failures-only --hosts \"carbon redbaron ryzen7\"" $?
# a plain session (no seat) stays silent and never runs the helper
rm -f "$T/args"; env -i PATH="$PATH" HOME="$T" TERM=dumb bash "$HOOK" </dev/null >/dev/null 2>&1; [ ! -e "$T/args" ]; chk "plain session: helper not run" $?
[ "$fail" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"; exit "$fail"
