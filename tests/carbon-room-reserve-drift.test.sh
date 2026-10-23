#!/usr/bin/env bash
# Drift guard: the carbon room reserve is defined twice -- DEFAULT_RESERVE in .local/bin/carbon-room.sh (the aide's pre-spawn check)
# and CARBON_ROOM_RESERVE_MB in fleet-dash/carbon_room.py (the dashboard field + alarm). Different numbers = two truths for "room".
# Both are extracted textually (never sourced/imported). The fleet-dash tree is read-only here; absent -> SKIP, exit 0.
# Run from anywhere:  bash tests/carbon-room-reserve-drift.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sh_file="$here/.local/bin/carbon-room.sh"
py_file="${FLEET_DASH_CARBON_ROOM_PY:-/home/jsy/wintermute/fleet-dash/carbon_room.py}"

if [ ! -f "$py_file" ]; then echo "SKIP fleet-dash tree absent"; exit 0; fi
[ -f "$sh_file" ] || { echo "FAIL carbon-room.sh missing: $sh_file"; exit 1; }

sh_val="$(sed -n 's/^DEFAULT_RESERVE=\([0-9][0-9]*\)\([[:space:]].*\)\{0,1\}$/\1/p' "$sh_file" | head -n1)"
py_val="$(sed -n 's/^CARBON_ROOM_RESERVE_MB[[:space:]]*=[[:space:]]*\([0-9][0-9]*\)\([[:space:]].*\)\{0,1\}$/\1/p' "$py_file" | head -n1)"
[ -n "$sh_val" ] || { echo "FAIL could not extract DEFAULT_RESERVE from $sh_file"; exit 1; }
[ -n "$py_val" ] || { echo "FAIL could not extract CARBON_ROOM_RESERVE_MB from $py_file"; exit 1; }

# the selftest header must print the same number the source defines (greppable value)
hdr="$(timeout 60 bash "$sh_file" --selftest 2>&1 | sed -n 's/^carbon-room selftest: DEFAULT_RESERVE=\([0-9][0-9]*\) MB$/\1/p' | head -n1)"
if [ "$hdr" != "$sh_val" ]; then echo "FAIL --selftest header reserve '$hdr' != DEFAULT_RESERVE '$sh_val'"; exit 1; fi

if [ "$sh_val" = "$py_val" ]; then echo "PASS carbon-room reserve: carbon-room.sh DEFAULT_RESERVE=$sh_val fleet-dash CARBON_ROOM_RESERVE_MB=$py_val"; exit 0; fi
echo "FAIL carbon-room reserve drift: carbon-room.sh DEFAULT_RESERVE=$sh_val != fleet-dash CARBON_ROOM_RESERVE_MB=$py_val"
exit 1
