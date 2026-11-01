#!/usr/bin/env bash
# r7-t7-health-bell: runs the script's --selftest (no ssh) and asserts EXIT=0 plus the PASS line.
# Run from anywhere:  bash tests/r7-t7-health-bell.test.sh   (R7_T7_BELL overrides the script path)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${R7_T7_BELL:-$here/.local/bin/r7-t7-health-bell.sh}"
[ -f "$script" ] || { echo "FAIL script missing: $script"; exit 1; }
out="$(bash "$script" --selftest 2>&1)"; rc=$?
echo "$out"
echo "EXIT=$rc"
[ "$rc" -eq 0 ] || { echo "FAIL selftest exit $rc"; exit 1; }
grep -qE '^SELFTEST PASS \([0-9]+ fixtures\)$' <<<"$out" || { echo "FAIL no SELFTEST PASS line"; exit 1; }
echo "PASS r7-t7-health-bell selftest"
