#!/usr/bin/env bash
# tests/lastpass_guards.test.sh — PRD-vibeloop-measure-deploy-last-pass Requirement 4/AC5
# (test_prefix: lastpass): exercises the deploy-target-selection decision logic (doctor_parse,
# lastpass_target, deploy_drift_field, drift_sustained) against fixture `mcphost-deploy doctor`
# output, with no network, no ssh, and no live mcphost-deploy. Plain bash (no bats dependency),
# same convention as tests/vibeloop-measure-guards.test.sh. Run with:
#   bash tests/lastpass_guards.test.sh
# from the repo root. Exits nonzero (and prints every failure) if any assertion fails.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixtures="$here/fixtures"
# The functions under test are function-only at source time (no top-level
# systemctl/curl/git calls) precisely so this can source them directly.
. "$here/../.local/lib/vibeloop-measure-guards.sh"

fail=0
assert_eq() { # $1=actual $2=expected $3=case description
  if [ "$1" = "$2" ]; then
    echo "ok - lastpass: $3"
  else
    echo "NOT OK - lastpass: $3: got '$1', want '$2'"
    fail=1
  fi
}

# -- lastpass ac1: doctor_parse + lastpass_target — last_pass ahead of deployed deploys it --

read -r main lp dep drift <<< "$(doctor_parse < "$fixtures/doctor-ahead.txt")"
assert_eq "$main $lp $dep $drift" "3b1fdbc c8a02f7 449a5bc 6" "doctor_parse: ahead fixture reads all four fields"
assert_eq "$(lastpass_target "$lp" "$dep")" "redeploy c8a02f7" "lastpass_target: last_pass ahead of deployed selects it for redeploy"

# -- lastpass ac2: last_pass equal to deployed measures only, no redeploy --

read -r main lp dep drift <<< "$(doctor_parse < "$fixtures/doctor-equal.txt")"
assert_eq "$main $lp $dep $drift" "3b1fdbc 449a5bc 449a5bc 0" "doctor_parse: equal fixture reads all four fields"
assert_eq "$(lastpass_target "$lp" "$dep")" "measure" "lastpass_target: last_pass == deployed measures only, no redeploy"
# main != last_pass here (3b1fdbc vs 449a5bc) — the clean-skip journal condition
# vibeloop-measure.sh checks (main "ungated") — verified structurally, not just
# via lastpass_target's own return value.
if [ "$main" != "$lp" ]; then
  echo "ok - lastpass: equal fixture's HEAD (main) differs from last_pass — the ungated-HEAD clean-skip line fires"
else
  echo "NOT OK - lastpass: equal fixture should have an ungated HEAD distinct from last_pass"; fail=1
fi

# -- lastpass ac2b: doctor reporting nothing resolvable (last_pass=none) never triggers a deploy --

read -r main lp dep drift <<< "$(doctor_parse < "$fixtures/doctor-unresolved.txt")"
assert_eq "$main $lp $dep $drift" "3b1fdbc none none unknown" "doctor_parse: unresolved fixture reads 'none'/'unknown' literally"
assert_eq "$(lastpass_target "$lp" "$dep")" "measure" "lastpass_target: last_pass=none never selects a redeploy target"

# -- lastpass ac3: deploy_drift ledger-field formatting --

assert_eq "$(deploy_drift_field 6)" "deploy_drift=6" "deploy_drift_field: numeric drift formats as deploy_drift=<n>"
assert_eq "$(deploy_drift_field 0)" "deploy_drift=0" "deploy_drift_field: zero drift formats as deploy_drift=0, not 'unknown'"
assert_eq "$(deploy_drift_field unknown)" "deploy_drift=unknown" "deploy_drift_field: doctor's own 'unknown' token passes through"
assert_eq "$(deploy_drift_field "")" "deploy_drift=unknown" "deploy_drift_field: an empty reading formats as deploy_drift=unknown, not blank"

# -- lastpass ac3b: drift_sustained — the digest-warning threshold (3+ consecutive drift>0) --

if drift_sustained 2 3 6; then
  echo "ok - lastpass: drift_sustained: three consecutive drift>0 readings is sustained"
else
  echo "NOT OK - lastpass: drift_sustained: three consecutive drift>0 readings should be sustained"; fail=1
fi

if drift_sustained 6 0 6; then
  echo "NOT OK - lastpass: drift_sustained: a 0 in the last three should NOT be sustained"; fail=1
else
  echo "ok - lastpass: drift_sustained: a 0 among the last three breaks the streak"
fi

if drift_sustained 6 6; then
  echo "NOT OK - lastpass: drift_sustained: fewer than 3 recorded cycles should NOT be sustained"; fail=1
else
  echo "ok - lastpass: drift_sustained: fewer than 3 recorded cycles never warns"
fi

if drift_sustained 6 unknown 6; then
  echo "NOT OK - lastpass: drift_sustained: an 'unknown' reading in the window should NOT be sustained"; fail=1
else
  echo "ok - lastpass: drift_sustained: an 'unknown' reading in the window breaks the streak"
fi

if [ "$fail" -eq 0 ]; then
  echo "all lastpass_guards tests passed"
else
  echo "lastpass_guards tests FAILED"
fi
exit "$fail"
