#!/usr/bin/env bash
# tests/noisefloor_ac5_ledger_summary_line.test.sh — PRD-mcphost-seed-noise-floor
# AC5: "Given three legs at one version, When the ledger is read, Then one
# summary line carries version, seeds, and overall spread."
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixtures="$here/fixtures"
. "$here/../.local/lib/vibeloop-measure-guards.sh"

fail=0
assert_contains() { # $1=haystack $2=needle $3=description
  case "$1" in *"$2"*) echo "ok - $3" ;; *) echo "NOT OK - $3: '$1' does not contain '$2'"; fail=1 ;; esac
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
nf="$work/noise-floor.json"
noise_floor_compute "0.44.0" "$nf" "" \
  "0:$fixtures/noisefloor-leg-seed0.json" \
  "17:$fixtures/noisefloor-leg-seed17.json" \
  "42:$fixtures/noisefloor-leg-seed42.json"

# the ONE line a reader of the ledger sees for a complete 3-leg sweep --
# this is exactly what run_noise_floor_sweep appends to $MLEDGER (prefixed
# with "$(ts) ") once noise_floor_compute above has written $NOISE_FLOOR.
line="$(noise_floor_ledger_line ok 0.44.0 0 17 42 "$nf")"
echo "line: $line"

assert_contains "$line" "version=0.44.0" "ledger summary line carries the version"
assert_contains "$line" "seeds=0,17,42" "ledger summary line carries all three seeds"
assert_contains "$line" "noise-floor=ok" "ledger summary line marks the sweep complete"
# overall satisfaction/wow spread computed in noisefloor_ac1: max_min=0.2,
# stddev≈0.0816 for both metrics (fixtures/noisefloor-leg-seed{0,17,42}.json).
assert_contains "$line" "overall_satisfaction_spread=0.2000/0.0816" \
  "ledger summary line carries the overall satisfaction spread"
assert_contains "$line" "overall_wow_spread=0.2000/0.0816" \
  "ledger summary line carries the overall wow_rate spread"
assert_contains "$line" "file=vibeloop/noise-floor.json" \
  "ledger summary line points at where the full detail lives"

# exactly one line's worth of content -- no embedded newlines (a multi-line
# "summary" would break the ledger's one-line-per-run convention).
line_count="$(printf '%s' "$line" | wc -l)"
if [ "$line_count" -eq 0 ]; then
  echo "ok - ledger summary line has no embedded newlines"
else
  echo "NOT OK - ledger summary line has $line_count embedded newline(s)"; fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "all noisefloor_ac5 tests passed"
else
  echo "noisefloor_ac5 tests FAILED"
fi
exit "$fail"
