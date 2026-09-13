#!/usr/bin/env bash
# tests/noisefloor_ac1_seed_sweep_shape.test.sh — PRD-mcphost-seed-noise-floor
# AC1: "Given a redeploy whose proxy gate passes, When the measure wiring
# completes, Then two additional proxy legs ran at the two other pinned
# seeds and noise-floor.json exists with per-segment values for all three
# seeds and correct spread math (fixture-verified)."
#
# Exercises the pure pieces directly (noise_floor_seeds, noise_floor_compute)
# against three fixture measure.json files shaped like synthorg's real
# build_measure() output (satisfaction/wow_rate, overall + by_segment) — no
# network, no synthorg, no uv. Run with: bash tests/noisefloor_ac1_seed_sweep_shape.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixtures="$here/fixtures"
. "$here/../.local/lib/vibeloop-measure-guards.sh"

fail=0
assert_eq() { # $1=actual $2=expected $3=description
  if [ "$1" = "$2" ]; then echo "ok - $3"
  else echo "NOT OK - $3: got '$1', want '$2'"; fail=1; fi
}

# -- noise_floor_seeds: leg one's seed passes through; legs two/three are
# the pinned NOISE_FLOOR_SEED_2/3 constants (default 17/42, never wall-clock) --
unset NOISE_FLOOR_SEED_2 NOISE_FLOOR_SEED_3
assert_eq "$(noise_floor_seeds 0)" "0 17 42" "noise_floor_seeds: defaults are 0 (leg one) 17 42"
assert_eq \
  "$(NOISE_FLOOR_SEED_2=99 NOISE_FLOOR_SEED_3=7 noise_floor_seeds 5)" "5 99 7" \
  "noise_floor_seeds: NOISE_FLOOR_SEED_2/3 override, leg-one seed still passed through"

# -- noise_floor_compute: all three legs present, correct per-segment values
# and spread math --
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
nf="$work/noise-floor.json"
noise_floor_compute "0.44.0" "$nf" "" \
  "0:$fixtures/noisefloor-leg-seed0.json" \
  "17:$fixtures/noisefloor-leg-seed17.json" \
  "42:$fixtures/noisefloor-leg-seed42.json"

if [ -f "$nf" ]; then echo "ok - noise-floor.json was written"
else echo "NOT OK - noise-floor.json was not written"; fail=1; fi

assert_eq "$(python3 -c "import json;print(json.load(open('$nf'))['version'])")" "0.44.0" \
  "noise-floor.json: version carried through"
assert_eq "$(python3 -c "import json;print(json.load(open('$nf'))['seeds'])")" "[0, 17, 42]" \
  "noise-floor.json: all three pinned seeds present"
assert_eq "$(python3 -c "import json;print(json.load(open('$nf'))['complete'])")" "True" \
  "noise-floor.json: complete=true when all three legs succeeded"

# per-segment values for all three seeds, AC1's own wording:
assert_eq "$(python3 -c "import json;d=json.load(open('$nf'));print(sorted(d['by_segment']))")" \
  "['data_analyst', 'ops_lead', 'rapid_prototyper']" \
  "noise-floor.json: every segment any leg reported appears in by_segment"
assert_eq "$(python3 -c "import json;d=json.load(open('$nf'));print(d['by_segment']['rapid_prototyper']['satisfaction'])")" \
  "{'0': 0.8, '17': 0.7, '42': 0.9}" \
  "noise-floor.json: rapid_prototyper satisfaction carries all three seeds' numeric values"

# ops_lead: seed 0's fixture reports the non-numeric floor text "n/a (n=1<3)"
# -- must read as null (absent, not zero), never coerced into the mean/spread.
assert_eq "$(python3 -c "import json;d=json.load(open('$nf'));print(d['by_segment']['ops_lead']['satisfaction']['0'])")" \
  "None" "noise-floor.json: ops_lead seed 0 (non-numeric 'n/a' text) reads as null, not 0"
assert_eq "$(python3 -c "import json;d=json.load(open('$nf'));print(d['by_segment']['ops_lead']['spread']['satisfaction']['n'])")" \
  "2" "noise-floor.json: ops_lead spread is computed over only the 2 numeric seeds"

# -- correct spread math: max-min and population stddev, per-segment and overall --
# rapid_prototyper / overall satisfaction / overall wow_rate: 0.80, 0.70, 0.90
# -> max_min=0.2, pstdev=0.08164965...
assert_eq "$(python3 -c "import json;d=json.load(open('$nf'));print(round(d['by_segment']['rapid_prototyper']['spread']['satisfaction']['max_min'],4))")" \
  "0.2" "spread math: rapid_prototyper satisfaction max_min = 0.2"
assert_eq "$(python3 -c "import json;d=json.load(open('$nf'));print(round(d['by_segment']['rapid_prototyper']['spread']['satisfaction']['stddev'],4))")" \
  "0.0816" "spread math: rapid_prototyper satisfaction stddev = 0.0816 (population)"
assert_eq "$(python3 -c "import json;d=json.load(open('$nf'));print(round(d['overall']['spread']['satisfaction']['max_min'],4))")" \
  "0.2" "spread math: overall satisfaction max_min = 0.2"
assert_eq "$(python3 -c "import json;d=json.load(open('$nf'));print(round(d['overall']['spread']['wow_rate']['stddev'],4))")" \
  "0.0816" "spread math: overall wow_rate stddev = 0.0816 (population)"

# data_analyst: identical 0.75 across all three seeds -> zero spread, not
# "unmeasurable" (3 numeric values, just all equal).
assert_eq "$(python3 -c "import json;d=json.load(open('$nf'));print(d['by_segment']['data_analyst']['spread']['satisfaction'])")" \
  "{'max_min': 0.0, 'stddev': 0.0, 'n': 3}" \
  "spread math: data_analyst satisfaction is identical across seeds -> spread 0, n=3 (not unmeasurable)"

if [ "$fail" -eq 0 ]; then
  echo "all noisefloor_ac1 tests passed"
else
  echo "noisefloor_ac1 tests FAILED"
fi
exit "$fail"
