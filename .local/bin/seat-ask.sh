#!/usr/bin/env bash
# seat-ask.sh <seat> "<text>": fast path to an operator seat. Starts one ASK turn as a transient user unit;
# seat-tick.sh's flock serializes it behind a running tick and waits up to 1800 s (an ask must land). Prints the unit name.
# SEAT_ASK_DRY=1 (or CTL_ASK_DRY=1) prints the command only. Seats come from ~/.claude/state/seats.tsv (SEATS_TABLE overrides).
set -u
[ $# -ge 2 ] || { echo 'usage: seat-ask.sh <seat> "<text>"' >&2; exit 64; }
seat="$1"; shift
awk -F'\t' -v s="$seat" '!/^[[:space:]]*(#|$)/ && $1==s {f=1} END{exit !f}' "${SEATS_TABLE:-$HOME/.claude/state/seats.tsv}" || { echo "seat-ask: unknown seat '$seat'" >&2; exit 64; }
unit="seat-ask-$seat-$(date +%s)-$$"
cmd=(systemd-run --user --collect --unit "$unit" -p "WorkingDirectory=$HOME" "$HOME/.local/bin/seat-tick.sh" "$seat" --ask "$*")
if [ "${SEAT_ASK_DRY:-${CTL_ASK_DRY:-}}" = 1 ]; then echo "${cmd[*]}"; exit 0; fi
"${cmd[@]}" >/dev/null 2>&1 || { echo "seat-ask: systemd-run failed" >&2; exit 1; }
echo "$unit"
