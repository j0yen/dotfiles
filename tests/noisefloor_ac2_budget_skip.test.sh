#!/usr/bin/env bash
# tests/noisefloor_ac2_budget_skip.test.sh — PRD-mcphost-seed-noise-floor
# AC2: "Given the day's session budget cannot cover the extra legs, When
# the sweep would start, Then it is skipped with skip: budget in the
# ledger, the gate verdict is unaffected, and no session is spent."
#
# `noise_floor_budget_ok` is the pure gate `run_noise_floor_sweep` checks
# BEFORE its for-loop that spends any session — by construction, a false
# return here means zero work dirs, zero `uv run synthorg` invocations.
# This file exercises that pure check plus the `skip-budget` ledger-line
# formatter directly; run_noise_floor_sweep itself (the orchestration that
# would actually spend a session) is not unit-tested here for the same
# reason run_proxy_gate isn't (see vibeloop-measure-guards.sh's own
# comment) — it's smoke-tested by hand instead.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/../.local/lib/vibeloop-measure-guards.sh"

fail=0
assert_eq() { # $1=actual $2=expected $3=description
  if [ "$1" = "$2" ]; then echo "ok - $3"
  else echo "NOT OK - $3: got '$1', want '$2'"; fail=1; fi
}

# -- noise_floor_budget_ok: covers it / doesn't cover it / uncapped --------

# runs24=0, max=10, one leg spends 3 sessions -> need 6 -> 0+6<=10 -> ok
if noise_floor_budget_ok 0 10 3; then
  echo "ok - noise_floor_budget_ok: plenty of budget left (0+6<=10) covers the sweep"
else
  echo "NOT OK - noise_floor_budget_ok: should have covered 0+6<=10"; fail=1
fi

# runs24=3 (the gate leg itself already spent 3), max=3 (MAX_MEASURES_PER_DAY
# default), one leg spends 3 sessions -> need 6 -> 3+6=9 > 3 -> cannot cover
if noise_floor_budget_ok 3 3 3; then
  echo "NOT OK - noise_floor_budget_ok: should NOT cover 3+6 > 3 (the day's cap)"; fail=1
else
  echo "ok - noise_floor_budget_ok: day's cap already spent covering just the gate leg -- sweep skips"
fi

# exactly at the cap boundary -> covers (inclusive <=)
if noise_floor_budget_ok 0 6 3; then
  echo "ok - noise_floor_budget_ok: exactly at the cap (0+6<=6) covers"
else
  echo "NOT OK - noise_floor_budget_ok: 0+6<=6 should cover (boundary inclusive)"; fail=1
fi

# one below the cap -> does not cover
if noise_floor_budget_ok 0 5 3; then
  echo "NOT OK - noise_floor_budget_ok: 0+6<=5 is false, should not cover"; fail=1
else
  echo "ok - noise_floor_budget_ok: one session short of the cap correctly refuses"
fi

# MAX_MEASURES_PER_DAY<=0 means uncapped (mirrors vibeloop-measure.sh's own
# budget_hit convention) -- always covers, regardless of runs24/leg size.
if noise_floor_budget_ok 999 0 999; then
  echo "ok - noise_floor_budget_ok: cap<=0 is uncapped, always covers"
else
  echo "NOT OK - noise_floor_budget_ok: cap<=0 should be uncapped"; fail=1
fi

# -- noise_floor_ledger_line skip-budget: the literal 'skip: budget' marker,
# version, and all three pinned seeds, AC2's own wording --
line="$(noise_floor_ledger_line skip-budget 0.44.0 0 17 42)"
case "$line" in
  *'noise-floor="skip: budget"'*) echo "ok - ledger line carries the literal skip: budget marker" ;;
  *) echo "NOT OK - ledger line missing 'skip: budget' marker: $line"; fail=1 ;;
esac
case "$line" in
  *'version=0.44.0'*) echo "ok - skip-budget ledger line names the version" ;;
  *) echo "NOT OK - skip-budget ledger line missing version=0.44.0: $line"; fail=1 ;;
esac
case "$line" in
  *'seeds=0,17,42'*) echo "ok - skip-budget ledger line names all three pinned seeds" ;;
  *) echo "NOT OK - skip-budget ledger line missing seeds=0,17,42: $line"; fail=1 ;;
esac

if [ "$fail" -eq 0 ]; then
  echo "all noisefloor_ac2 tests passed"
else
  echo "noisefloor_ac2 tests FAILED"
fi
exit "$fail"
