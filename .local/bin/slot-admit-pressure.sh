#!/usr/bin/env bash
# slot-admit-pressure.sh --open N [--max-swap-gib G] [--max-psi-full10 P] [--at N] - memory-pressure floor for parallel-slot admission.
# When the new slot would reach --at open runs (default 3): swap used (SwapTotal-SwapFree) > G GiB (default 4)
# or PSI memory "full" avg10 >= P (default 10) -> "REFUSE pressure swap=X.XG psi_full10=Y open=N", exit 1;
# else "OK pressure swap=X.XG psi_full10=Y open=N", exit 0. Below --at: "OK pressure n/a open=N", exit 0.
# Unreadable or unparsable input -> stderr message, exit 2. Inputs: SLOT_ADMIT_MEMINFO (default /proc/meminfo),
# SLOT_ADMIT_PSI (default /proc/pressure/memory). Gates admission only; it never changes max_runs.
# Launchers call it as: slot-admit-pressure.sh --open N || exit 75
set -u
usage="usage: $0 --open N [--max-swap-gib G] [--max-psi-full10 P] [--at N]"
open=""
maxswap=4
maxpsi=10
at=3
while [ $# -gt 0 ]; do
  case $1 in
    --open) [ $# -ge 2 ] || { echo "$usage" >&2; exit 2; }; open=$2; shift 2 ;;
    --max-swap-gib) [ $# -ge 2 ] || { echo "$usage" >&2; exit 2; }; maxswap=$2; shift 2 ;;
    --max-psi-full10) [ $# -ge 2 ] || { echo "$usage" >&2; exit 2; }; maxpsi=$2; shift 2 ;;
    --at) [ $# -ge 2 ] || { echo "$usage" >&2; exit 2; }; at=$2; shift 2 ;;
    -h|--help) echo "$usage"; exit 0 ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
done
isint() { case $1 in ''|*[!0-9]*) return 1 ;; esac; }
isnum() { case $1 in ''|.|*[!0-9.]*|*.*.*) return 1 ;; esac; }
isint "$open" || { echo "bad --open: ${open:-missing}" >&2; exit 2; }
isint "$at" || { echo "bad --at: $at" >&2; exit 2; }
isnum "$maxswap" || { echo "bad --max-swap-gib: $maxswap" >&2; exit 2; }
isnum "$maxpsi" || { echo "bad --max-psi-full10: $maxpsi" >&2; exit 2; }
if [ $((open + 1)) -lt "$at" ]; then echo "OK pressure n/a open=$open"; exit 0; fi
meminfo=${SLOT_ADMIT_MEMINFO:-/proc/meminfo}
psi=${SLOT_ADMIT_PSI:-/proc/pressure/memory}
[ -r "$meminfo" ] || { echo "slot-admit-pressure: cannot read $meminfo" >&2; exit 2; }
[ -r "$psi" ] || { echo "slot-admit-pressure: cannot read $psi" >&2; exit 2; }
swapkb=$(awk '/^SwapTotal:/{t=$2; ht=1} /^SwapFree:/{f=$2; hf=1} END{if (ht && hf && t ~ /^[0-9]+$/ && f ~ /^[0-9]+$/ && t >= f) print t-f}' "$meminfo")
isint "$swapkb" || { echo "slot-admit-pressure: cannot parse SwapTotal/SwapFree in $meminfo" >&2; exit 2; }
p10=$(awk '$1=="full"{for(i=2;i<=NF;i++) if ($i ~ /^avg10=/) {sub(/^avg10=/,"",$i); print $i}}' "$psi")
isnum "$p10" || { echo "slot-admit-pressure: cannot parse full avg10 in $psi" >&2; exit 2; }
swapg=$(awk -v k="$swapkb" 'BEGIN{printf "%.1f", k/1048576}')
refuse=$(awk -v k="$swapkb" -v ms="$maxswap" -v p="$p10" -v mp="$maxpsi" 'BEGIN{print ((k > ms*1048576) || (p+0 >= mp+0)) ? 1 : 0}')
if [ "$refuse" = 1 ]; then echo "REFUSE pressure swap=${swapg}G psi_full10=$p10 open=$open"; exit 1; fi
echo "OK pressure swap=${swapg}G psi_full10=$p10 open=$open"
