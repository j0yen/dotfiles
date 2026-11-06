#!/usr/bin/env bash
# timers-lint (hermes-handover 2.5): timers.tsv matches the unit files, and every launching unit is hold-gated
# (a 99-joe-quota-conservation.conf drop-in or hold-gate.sh in its ExecStart script; HOLD_EXEMPT units show as `exempt`).
# Exit 0 + "findings: 0" when clean; exit 1 with one line per finding and "findings: N" last.
set -uo pipefail
root="${TIMERS_ROOT:-$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)}"
export TIMERS_ROOT="$root"
gen="$(dirname "$(readlink -f "$0")")/timers-gen.py"
n=0
if ! out="$(python3 -I "$gen" --check 2>&1)"; then
  printf '%s\n' "$out" | head -20
  echo "FINDING timers.tsv drifted from the unit files"
  n=$((n + 1))
fi
# judge the freshly generated rows, so a stale committed TSV never hides an ungated launching unit
tsv="$root/.config/fleet/timers.tsv"
if [ ! -f "$tsv" ]; then echo "FINDING timers.tsv missing"; n=$((n + 1)); fi
if gen_out="$(python3 -I "$gen" --stdout 2>&1)"; then
  while IFS=$'\t' read -r unit cls owner gated enabled; do
    [ "$unit" = unit ] && continue
    if [ "$cls" = launching ] && [ "$gated" = no ]; then
      echo "FINDING launching unit $unit is not hold-gated (add a 99-joe-quota-conservation.conf drop-in)"
      n=$((n + 1))
    fi
  done <<< "$gen_out"
else
  echo "FINDING timers-gen.py failed: $gen_out"; n=$((n + 1))
fi
echo "findings: $n"
[ "$n" -eq 0 ]
