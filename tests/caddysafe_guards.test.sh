#!/usr/bin/env bash
# tests/caddysafe_guards.test.sh — PRD-mcphost-deploy-caddy-reload-safety
# (test_prefix: caddysafe): exercises the two guard changes this PRD made to
# vibeloop-measure-guards.sh -- AC9 (classify_deploy_outcome now treats
# EXIT_ROLLBACK, rc=3, as rolled-back regardless of text, the fix for the
# 09-14/09-16 incident's 25-rollback loop) and AC11 (the repeated-rollback
# backstop alarm). Plain bash (no bats dependency), same convention as
# tests/vibeloop-measure-guards.test.sh/tests/selfauth_guards.test.sh. Run
# with:
#   bash tests/caddysafe_guards.test.sh
# from the repo root. Exits nonzero (and prints every failure) if any
# assertion fails.
#
# Scope note: the full vibeloop-measure.sh wiring (reading the previous
# ledger line for the same sha, appending the alarm to
# ~/brain/journal/vibeloop-measure.log and the ledger line itself) is not
# driven end to end here -- same precedent as selfauth_guards.test.sh's own
# scope note. This exercises the decision/formatting functions
# vibeloop-measure.sh calls (classify_deploy_outcome, repeated_rollback,
# rollback_alarm_line) directly.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The functions under test are function-only at source time (no top-level
# systemctl/curl/git calls) precisely so this can source them directly.
. "$here/../.local/lib/vibeloop-measure-guards.sh"

fail=0
assert_eq() { # $1=actual $2=expected $3=case description
  if [ "$1" = "$2" ]; then
    echo "ok - caddysafe: $3"
  else
    echo "NOT OK - caddysafe: $3: got '$1', want '$2'"
    fail=1
  fi
}

# -- AC9: classify_deploy_outcome treats rc=3 (EXIT_ROLLBACK) as rolled-back
# regardless of whether the printed text contains the literal token --------

read -r outcome cause <<< "$(classify_deploy_outcome 3 "redeploy of 0.54.1 failed probe; rolled back to 0.51.0")"
assert_eq "$outcome $cause" "rolled-back none" \
  "classify_deploy_outcome: rc=3 with the OLD (pre-fix) space-separated wording still classifies rolled-back"

read -r outcome cause <<< "$(classify_deploy_outcome 3 "redeploy  rolled-back  (cause=access-log to=0.51.0)")"
assert_eq "$outcome $cause" "rolled-back access-log" \
  "classify_deploy_outcome: rc=3 with the fixed hyphenated wording classifies rolled-back, cause parsed from it"

read -r outcome cause <<< "$(classify_deploy_outcome 3 "some other text entirely, no token at all")"
assert_eq "$outcome $cause" "rolled-back none" \
  "classify_deploy_outcome: rc=3 with no rollback-shaped text at all still classifies rolled-back (the exit code IS the signal)"

read -r outcome cause <<< "$(classify_deploy_outcome 2 "redeploy  refused  (cause=ungated sha=abc1234)")"
assert_eq "$outcome $cause" "refused ungated" \
  "classify_deploy_outcome: a non-rollback, non-zero rc (2) without the token still classifies refused"

read -r outcome cause <<< "$(classify_deploy_outcome 0 "redeployed 0.54.1 (mcphost-1)")"
assert_eq "$outcome $cause" "deployed none" \
  "classify_deploy_outcome: rc=0 is unaffected by the rc=3 special case"

# -- AC10: the fixed classification + the pre-existing pointer pair round-trip
# (the "stub mcphost-deploy on PATH" fixture harness and the "skip:
# rolled-back-pending-new-green" log line themselves are vibeloop-measure.sh's
# own orchestration -- unchanged by, and out of scope for, this PRD's one-
# function-plus-alarm cross-repo edit; this exercises the two pieces R6's fix
# makes newly correct together: a rollback now classifies right, and
# record_rolled_back_pending/rolled_back_pending -- pre-existing, untouched --
# then do their job) -----------------------------------------------------

tmp_state_dir="$(mktemp -d)"
tmp_state="$tmp_state_dir/rolled-back-last-pass"
read -r outcome cause <<< "$(classify_deploy_outcome 3 "redeploy  rolled-back  (cause=access-log to=0.51.0)")"
if [ "$outcome" = "rolled-back" ]; then
  record_rolled_back_pending "$tmp_state" "sha-green-1"
fi
if rolled_back_pending "$tmp_state" "sha-green-1"; then
  echo "ok - caddysafe: AC10: a rolled-back classification (now correct thanks to R6) writes the pointer, and the same last_pass sha reads back pending"
else
  echo "NOT OK - caddysafe: AC10: pointer round-trip failed"; fail=1
fi
if rolled_back_pending "$tmp_state" "sha-green-2"; then
  echo "NOT OK - caddysafe: AC10: a NEW last_pass sha should not read as pending"; fail=1
else
  echo "ok - caddysafe: AC10: a new last_pass sha (new green) is not held pending"
fi
rm -rf "$tmp_state_dir"

# -- AC11: the repeated-rollback backstop alarm ------------------------------

if repeated_rollback "rolled-back" "sha-aaa" "rolled-back" "sha-aaa"; then
  echo "ok - caddysafe: repeated_rollback: two consecutive rolled-back outcomes for the same sha fires"
else
  echo "NOT OK - caddysafe: repeated_rollback: should fire on two consecutive rolled-back outcomes for the same sha"; fail=1
fi

if repeated_rollback "rolled-back" "sha-aaa" "rolled-back" "sha-bbb"; then
  echo "NOT OK - caddysafe: repeated_rollback: should NOT fire when the sha changed between runs"; fail=1
else
  echo "ok - caddysafe: repeated_rollback: a changed sha between runs does not fire"
fi

if repeated_rollback "rolled-back" "sha-aaa" "deployed" "sha-aaa"; then
  echo "NOT OK - caddysafe: repeated_rollback: should NOT fire when the previous run was not a rollback"; fail=1
else
  echo "ok - caddysafe: repeated_rollback: a non-rollback previous run does not fire"
fi

if repeated_rollback "deployed" "sha-aaa" "rolled-back" "sha-aaa"; then
  echo "NOT OK - caddysafe: repeated_rollback: should NOT fire when the CURRENT run is not a rollback"; fail=1
else
  echo "ok - caddysafe: repeated_rollback: a non-rollback current run does not fire"
fi

assert_eq "$(rollback_alarm_line sha-aaa access-log)" "ALARM redeploy-rolled-back-twice sha=sha-aaa cause=access-log" \
  "rollback_alarm_line: exact alarm text"
assert_eq "$(rollback_alarm_line "" "")" "ALARM redeploy-rolled-back-twice sha=unknown cause=none" \
  "rollback_alarm_line: missing sha/cause default to 'unknown'/'none', never a blank field"

if [ "$fail" -eq 0 ]; then
  echo "all caddysafe guards tests passed"
else
  echo "caddysafe guards tests FAILED"
fi
exit "$fail"
