#!/usr/bin/env bash
# tests/noisefloor_ac3_leg_failure_incomplete.test.sh — PRD-mcphost-seed-noise-floor
# AC3: "Given leg three fails (fake synthorg exits nonzero), When the run
# completes, Then the gate verdict stands, noise-floor: incomplete is
# recorded, and the ledger names the failed leg."
#
# `run_noise_floor_sweep` reacts to a failed leg (no measure.json written)
# by omitting that seed from the pairs it hands noise_floor_compute and
# adding it to the failed-seeds csv — this test drives noise_floor_compute
# and noise_floor_ledger_line directly with exactly that shape (legs one
# and two present, leg three absent/failed), which is the same input
# run_noise_floor_sweep would produce after a real failed `uv run synthorg`
# call. "The gate verdict stands" is true by construction: this whole path
# only ever runs from inside run_noise_floor_sweep, which vibeloop-measure.sh
# calls without `|| exit` (see its own comment at the call site) — nothing
# here can alter $redeploy_rc, $deploy_outcome, or the proxy gate's own
# earlier pass/fail, which already happened and returned before this
# function was ever invoked.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixtures="$here/fixtures"
. "$here/../.local/lib/vibeloop-measure-guards.sh"

fail=0
assert_eq() { # $1=actual $2=expected $3=description
  if [ "$1" = "$2" ]; then echo "ok - $3"
  else echo "NOT OK - $3: got '$1', want '$2'"; fail=1; fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
nf="$work/noise-floor.json"

# Leg three (seed 42) failed -- only seed 0 (the gate leg) and seed 17's
# measure.json are handed in, plus "42" in the failed-seeds csv.
noise_floor_compute "0.44.0" "$nf" "42" \
  "0:$fixtures/noisefloor-leg-seed0.json" \
  "17:$fixtures/noisefloor-leg-seed17.json"

assert_eq "$(python3 -c "import json;print(json.load(open('$nf'))['complete'])")" "False" \
  "noise-floor.json: complete=false when a leg failed"
assert_eq "$(python3 -c "import json;print(json.load(open('$nf'))['failed_seeds'])")" "[42]" \
  "noise-floor.json: failed_seeds names exactly the failed leg"
assert_eq "$(python3 -c "import json;print(json.load(open('$nf'))['seeds'])")" "[0, 17]" \
  "noise-floor.json: seeds lists only the legs that actually produced a measure.json"

# Spread is still computed from whatever numeric data two legs give —
# rapid_prototyper satisfaction 0.80 (seed 0) and 0.70 (seed 17):
assert_eq "$(python3 -c "import json;d=json.load(open('$nf'));s=d['by_segment']['rapid_prototyper']['spread']['satisfaction'];print(round(s['max_min'],4), round(s['stddev'],4), s['n'])")" \
  "0.1 0.05 2" \
  "noise-floor.json: partial (2-leg) spread math is still correct, not dropped"

# -- noise_floor_ledger_line incomplete: names the failed leg, AC3's own wording --
line="$(noise_floor_ledger_line incomplete 0.44.0 0 17 42 "$nf" "42")"
case "$line" in
  *'noise-floor=incomplete'*) echo "ok - ledger line carries the literal 'noise-floor=incomplete' marker" ;;
  *) echo "NOT OK - ledger line missing noise-floor=incomplete: $line"; fail=1 ;;
esac
case "$line" in
  *'failed_seeds=42'*) echo "ok - ledger line names the failed leg's seed (42)" ;;
  *) echo "NOT OK - ledger line does not name the failed seed: $line"; fail=1 ;;
esac
case "$line" in
  *'version=0.44.0'*) echo "ok - incomplete ledger line still names the version" ;;
  *) echo "NOT OK - incomplete ledger line missing version: $line"; fail=1 ;;
esac

# -- every seed can fail (leg one's own measure.json missing entirely) --
# cannot happen in practice (run_noise_floor_sweep returns before this
# point when $leg1_json doesn't exist — see its own guard), but
# noise_floor_compute itself must still degrade gracefully rather than
# crash on an empty pairs list.
noise_floor_compute "0.44.0" "$work/empty.json" "0,17,42"
assert_eq "$(python3 -c "import json;print(json.load(open('$work/empty.json'))['seeds'])")" "[]" \
  "noise_floor_compute: zero successful legs still writes valid (empty) JSON, does not crash"

if [ "$fail" -eq 0 ]; then
  echo "all noisefloor_ac3 tests passed"
else
  echo "noisefloor_ac3 tests FAILED"
fi
exit "$fail"
