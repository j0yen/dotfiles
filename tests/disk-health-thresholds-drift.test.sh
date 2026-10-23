#!/usr/bin/env bash
# Drift guard: the disk bytes thresholds are defined twice -- BYTES_YELLOW_PCT / BYTES_RED_PCT in .local/bin/disk-health.sh (the per-mount
# bytes_level in the collector file) and in fleet-dash/disk_health.py (the `disk-health` alarm). Different numbers = two truths for "full".
# Both are extracted textually (never sourced/imported). The fleet-dash tree is read-only here; absent -> SKIP, exit 0.
# Run from anywhere:  bash tests/disk-health-thresholds-drift.test.sh   (FLEET_DASH_DISK_HEALTH_PY overrides the fleet-dash file)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sh_file="$here/.local/bin/disk-health.sh"
py_file="${FLEET_DASH_DISK_HEALTH_PY:-/home/jsy/wintermute/fleet-dash/disk_health.py}"

if [ ! -f "$py_file" ]; then echo "SKIP fleet-dash tree absent"; exit 0; fi
[ -f "$sh_file" ] || { echo "FAIL disk-health.sh missing: $sh_file"; exit 1; }

# <NAME> = <int> at the start of a line (shell-python block and python module alike), optional trailing comment
grab() { sed -n "s/^$1[[:space:]]*=[[:space:]]*\([0-9][0-9]*\)\([[:space:]].*\)\{0,1\}\$/\1/p" "$2" | head -n1; }
rc=0
for name in BYTES_YELLOW_PCT BYTES_RED_PCT; do
  sh_val="$(grab "$name" "$sh_file")"
  py_val="$(grab "$name" "$py_file")"
  [ -n "$sh_val" ] || { echo "FAIL could not extract $name from $sh_file"; exit 1; }
  [ -n "$py_val" ] || { echo "FAIL could not extract $name from $py_file"; exit 1; }
  if [ "$sh_val" = "$py_val" ]; then echo "PASS disk-health $name: disk-health.sh=$sh_val fleet-dash=$py_val"
  else echo "FAIL disk-health $name drift: disk-health.sh=$sh_val != fleet-dash=$py_val"; rc=1; fi
done
exit $rc
