#!/usr/bin/env bash
# seat-tick-failed.sh <seat>: run by seat-tick-failed@<seat>.service (OnFailure= of seat-tick@<seat>.service). Raises
#   seat-event.sh ctl "SEAT-TICK FAILED seat=<seat>: <last useful journal line of seat-tick@<seat>>"   (EVENT_SOURCE=seat-tick-failed)
# so the controller learns of a dead tick in seconds. Exceptions:
#   seat = ctl : SEAT_EVENT_NOWAKE=1 (event log only; a failing ctl tick must not spawn another ctl tick). The next ctl tick reads it.
#   exit 5     : lock-busy skip, not a failure (seat-tick.sh counts it; the dash alarms at 3 in a row), so no event.
# Env (selftest): SEAT_EVENT_BIN, SEAT_FAILED_STATUS (instead of systemctl show ExecMainStatus), SEAT_FAILED_JOURNAL (file instead of journalctl).
set -u
export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
EVENT_BIN="${SEAT_EVENT_BIN:-$HOME/.local/bin/seat-event.sh}"

selftest() {
  local T fail=0 out; T="$(mktemp -d)"; trap 'rm -rf "$T"' RETURN
  chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
  printf '#!/bin/bash\necho "nowake=${SEAT_EVENT_NOWAKE:-} src=${EVENT_SOURCE:-} args=$*" >>"%s/calls"\n' "$T" >"$T/fake-event"; chmod +x "$T/fake-event"
  export SEAT_EVENT_BIN="$T/fake-event"
  printf "seat-tick: rb tick model=x\nALARM rb guard: interactive seat still running\nseat-tick@rb.service: Main process exited, code=exited, status=4/n/a\nseat-tick@rb.service: Failed with result 'exit-code'.\nFailed to start operator seat rb.\n" >"$T/journal"
  SEAT_FAILED_JOURNAL="$T/journal" SEAT_FAILED_STATUS=4 "$SELF" rb
  [ "$(cat "$T/calls")" = 'nowake= src=seat-tick-failed args=ctl SEAT-TICK FAILED seat=rb: ALARM rb guard: interactive seat still running' ]; chk "rb failure -> ctl event with wake, last useful journal line ($(cut -c1-110 "$T/calls"))" $?
  : >"$T/calls"; SEAT_FAILED_JOURNAL="$T/journal" SEAT_FAILED_STATUS=4 "$SELF" ctl
  grep -q '^nowake=1 .*args=ctl SEAT-TICK FAILED seat=ctl: ' "$T/calls"; chk "ctl failure -> event with SEAT_EVENT_NOWAKE=1 (no loop)" $?
  : >"$T/calls"; SEAT_FAILED_JOURNAL="$T/journal" SEAT_FAILED_STATUS=5 "$SELF" r7
  [ ! -s "$T/calls" ]; chk "exit 5 (lock busy) -> no event" $?
  : >"$T/calls"; : >"$T/empty"; SEAT_FAILED_JOURNAL="$T/empty" SEAT_FAILED_STATUS=124 "$SELF" r7
  grep -q 'seat=r7: exit 124, no journal output$' "$T/calls"; chk "empty journal -> 'exit 124, no journal output'" $?
  "$SELF" >/dev/null 2>&1; [ $? = 64 ]; chk "no seat: exit 64" $?
  [ "$fail" = 0 ] && echo "SELFTEST PASS" || echo "SELFTEST FAIL"; return "$fail"
}
[ "${1:-}" = "--selftest" ] && { selftest; exit $?; }
[ $# -eq 1 ] || { echo 'usage: seat-tick-failed.sh <seat> | --selftest' >&2; exit 64; }
seat="$1"; unit="seat-tick@$seat.service"
st="${SEAT_FAILED_STATUS:-$(systemctl --user show "$unit" -p ExecMainStatus --value 2>/dev/null)}"
[ "$st" = 5 ] && exit 0
if [ -n "${SEAT_FAILED_JOURNAL:-}" ]; then jl="$(cat "$SEAT_FAILED_JOURNAL")"; else jl="$(journalctl --user -u "$unit" -n 40 -o cat --no-pager 2>/dev/null)"; fi
last="$(printf '%s\n' "$jl" | grep -v -e "^seat-tick@$seat.service: " -e '^Failed to start' -e '^Consumed ' -e '^Started ' -e '^$' | tail -n1 | cut -c1-200)"
[ -n "$last" ] || last="exit ${st:-?}, no journal output"
export EVENT_SOURCE=seat-tick-failed
[ "$seat" = ctl ] && export SEAT_EVENT_NOWAKE=1
exec "$EVENT_BIN" ctl "SEAT-TICK FAILED seat=$seat: $last"
