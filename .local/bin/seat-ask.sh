#!/usr/bin/env bash
# seat-ask.sh <seat> "<text>": fast path to an operator seat. Starts one ASK turn as a transient user unit;
# seat-tick.sh's flock serializes it behind a running tick and waits up to 1800 s (an ask must land). Prints the unit name.
# SEAT_ASK_DRY=1 (or CTL_ASK_DRY=1) prints the command only. A guard refusal (unit exit 4) or missing goal line (6) within 5 s prints `ASK REFUSED <seat>: <last line>` on stderr and exits that code.
# SEAT_ASK_TICK_BIN overrides the seat-tick.sh path (selftest fake only). Seats come from ~/.claude/state/seats.tsv (SEATS_TABLE overrides).
set -u
[ $# -ge 2 ] || { echo 'usage: seat-ask.sh <seat> "<text>"' >&2; exit 64; }
seat="$1"; shift
awk -F'\t' -v s="$seat" '!/^[[:space:]]*(#|$)/ && $1==s {f=1} END{exit !f}' "${SEATS_TABLE:-$HOME/.claude/state/seats.tsv}" || { echo "seat-ask: unknown seat '$seat'" >&2; exit 64; }
unit="seat-ask-$seat-$(date +%s)-$$"
cmd=(systemd-run --user --collect --unit "$unit" -p "WorkingDirectory=$HOME" "${SEAT_ASK_TICK_BIN:-$HOME/.local/bin/seat-tick.sh}" "$seat" --ask "$*")
if [ "${SEAT_ASK_DRY:-${CTL_ASK_DRY:-}}" = 1 ]; then echo "${cmd[*]}"; exit 0; fi
"${cmd[@]}" >/dev/null 2>&1 || { echo "seat-ask: systemd-run failed" >&2; exit 1; }
# A refused ASK must not look like success: wait up to 5 s for the transient unit to exit. --collect unloads the unit, so the exit status
# is read from the user journal ("Main process exited, code=exited, status=N"). 4 = guard refusal, 6 = no /goal line: print the unit's last
# output line, exit that code. A unit still running after 5 s (waiting on the seat lock, or mid-turn) is accepted: prints the unit name.
rc=""; gone=""
for _ in $(seq 1 20); do
  systemctl --user is-active -q "$unit.service" 2>/dev/null || gone=1   # state first, journal second: an exit between the two is still read
  jl="$(journalctl --user -u "$unit.service" -o cat --no-pager 2>/dev/null)"
  rc="$(printf '%s\n' "$jl" | sed -n 's/.*Main process exited, code=exited, status=\([0-9][0-9]*\)\/.*/\1/p' | tail -n1)"
  [ -n "$rc" ] || [ -n "$gone" ] && break
  sleep 0.25
done
case "$rc" in
  4|6)
    last="$(printf '%s\n' "$jl" | grep -v -e "^$unit\.service: " -e '^Started ' -e '^Consumed ' | tail -n1)"
    echo "ASK REFUSED $seat: ${last:-exit $rc, no output}" >&2; exit "$rc" ;;
esac
echo "$unit"
