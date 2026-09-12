#!/usr/bin/env bash
# tests/selfauth_guards.test.sh — PRD-vibeloop-measure-self-authorized-redeploy
# (test_prefix: selfauth): exercises the measure step's own migrate-authorization
# decision logic (authorize-range construction, the unattended killswitch, outcome
# classification off a redeploy call's exit code + printed journal line, the
# rolled-back "don't retry the same range" state, and the ledger/measure.json field
# formatting) against fixture inputs, with no network, no ssh, no live
# mcphost-deploy, and no `uv run`. Plain bash (no bats dependency), same convention
# as tests/vibeloop-measure-guards.test.sh and tests/lastpass_guards.test.sh. Run
# with:
#   bash tests/selfauth_guards.test.sh
# from the repo root. Exits nonzero (and prints every failure) if any assertion
# fails.
#
# Scope note: the actual `cd "$DEPLOY" && uv run mcphost-deploy redeploy ...`
# shell-out in vibeloop-measure.sh is not driven end-to-end here (same precedent
# as lastpass_guards.test.sh, which stops at doctor_parse/lastpass_target rather
# than invoking a live/fake `uv run mcphost-deploy doctor`) — AC1's exact argv is
# covered below by asserting the flag/env decision functions vibeloop-measure.sh
# itself calls to build that command line, and AC9 (the live lane, post-ship) is
# an operational check outside a hermetic test's reach.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The functions under test are function-only at source time (no top-level
# systemctl/curl/git calls) precisely so this can source them directly.
. "$here/../.local/lib/vibeloop-measure-guards.sh"

fail=0
assert_eq() { # $1=actual $2=expected $3=case description
  if [ "$1" = "$2" ]; then
    echo "ok - selfauth: $3"
  else
    echo "NOT OK - selfauth: $3: got '$1', want '$2'"
    fail=1
  fi
}

# -- AC1: MCPHOST_DEPLOY_AUTHORIZE range + the migrate-flag decision ---------

assert_eq "$(deploy_authorize_range aaa1111 bbb2222)" "aaa1111..bbb2222" \
  "deploy_authorize_range: <deployed>..<last_pass>, in that order"
assert_eq "$(deploy_authorize_range "" "")" "unknown..unknown" \
  "deploy_authorize_range: missing shas format as 'unknown..unknown', not blank"

if MEASURE_UNATTENDED_DEPLOY=on unattended_deploy_enabled; then
  echo "ok - selfauth: unattended_deploy_enabled: MEASURE_UNATTENDED_DEPLOY=on is enabled"
else
  echo "NOT OK - selfauth: unattended_deploy_enabled: MEASURE_UNATTENDED_DEPLOY=on should be enabled"; fail=1
fi
if (unset MEASURE_UNATTENDED_DEPLOY; unattended_deploy_enabled); then
  echo "ok - selfauth: unattended_deploy_enabled: unset defaults to enabled"
else
  echo "NOT OK - selfauth: unattended_deploy_enabled: unset should default to enabled"; fail=1
fi
if MEASURE_UNATTENDED_DEPLOY=off unattended_deploy_enabled; then
  echo "NOT OK - selfauth: unattended_deploy_enabled: MEASURE_UNATTENDED_DEPLOY=off should be disabled"; fail=1
else
  echo "ok - selfauth: unattended_deploy_enabled: MEASURE_UNATTENDED_DEPLOY=off is disabled"
fi

assert_eq "$(redeploy_migrate_flags 1 | tr '\n' ' ')" "--migrate-incompatible --authorized-by vibeloop-measure " \
  "redeploy_migrate_flags: enabled prints the two flags, --authorized-by vibeloop-measure"
assert_eq "$(redeploy_migrate_flags 0)" "" \
  "redeploy_migrate_flags: disabled prints nothing (the plain --skip-if-ungated call)"

# -- AC2: a clean redeploy classifies as deployed, cause=none ----------------

read -r outcome cause <<< "$(classify_deploy_outcome 0 "redeploy  ok  (sha=bbb2222)")"
assert_eq "$outcome $cause" "deployed none" \
  "classify_deploy_outcome: rc=0, no cause= in the output, classifies deployed/none"

# -- AC3: a non-zero exit with a rolled-back journal line --------------------

read -r outcome cause <<< "$(classify_deploy_outcome 3 "redeploy  rolled-back  (cause=migrate-failed backup=/var/backups/mcphost/x.db)")"
assert_eq "$outcome $cause" "rolled-back migrate-failed" \
  "classify_deploy_outcome: non-zero rc + a 'rolled-back' line classifies rolled-back, cause parsed from it"

# -- AC4: rc=5 with a refused journal line -----------------------------------

read -r outcome cause <<< "$(classify_deploy_outcome 5 "redeploy  refused  (cause=gate-ungated sha=bbb2222 last_pass=bbb2222)")"
assert_eq "$outcome $cause" "refused gate-ungated" \
  "classify_deploy_outcome: rc=5, no 'rolled-back' line, classifies refused with the printed cause"

# a refusal that printed no parseable cause= token still classifies refused/none,
# never crashes or leaves cause blank.
read -r outcome cause <<< "$(classify_deploy_outcome 5 "some unrelated remote/ELF error before the switch")"
assert_eq "$outcome $cause" "refused none" \
  "classify_deploy_outcome: a refusal with no cause= token reads cause=none, not blank"

# -- AC6: MEASURE_UNATTENDED_DEPLOY=off forces cause=disabled-by-step --------
# (vibeloop-measure.sh itself does the override — `[ "$unattended" != 1 ] &&
# deploy_cause=disabled-by-step` — this asserts the flag/env-building half of
# that path: no migrate flags, so the call could never have printed an
# incompatible-migration cause in the first place.)

assert_eq "$(redeploy_migrate_flags 0)" "" \
  "AC6: unattended disabled builds a call with no migrate flags at all"

# -- AC8: rolled-back-pending-new-green state -- last_pass, not the whole range --

tmp_state="$(mktemp -u)/rolled-back-last-pass"
trap 'rm -rf "$(dirname "$tmp_state")"' EXIT

if rolled_back_pending "$tmp_state" bbb2222; then
  echo "NOT OK - selfauth: rolled_back_pending: no state file yet should never be pending"; fail=1
else
  echo "ok - selfauth: rolled_back_pending: no state file yet is never pending"
fi

record_rolled_back_pending "$tmp_state" bbb2222
if rolled_back_pending "$tmp_state" bbb2222; then
  echo "ok - selfauth: rolled_back_pending: same last_pass (bbb2222) as the recorded rollback is pending"
else
  echo "NOT OK - selfauth: rolled_back_pending: same last_pass as the recorded rollback should be pending"; fail=1
fi

# AC8's second half: last_pass moves to a new green build (ccc3333) — the hold
# lifts on its own, no separate "clear" call needed for this case.
if rolled_back_pending "$tmp_state" ccc3333; then
  echo "NOT OK - selfauth: rolled_back_pending: a new last_pass (ccc3333) should not be pending"; fail=1
else
  echo "ok - selfauth: rolled_back_pending: a new last_pass (ccc3333) is not pending — the range is retried"
fi

# a successful deploy explicitly clears the hold (vibeloop-measure.sh calls this
# right after a redeploy_ok ledger write).
record_rolled_back_pending "$tmp_state" bbb2222
clear_rolled_back_pending "$tmp_state"
if rolled_back_pending "$tmp_state" bbb2222; then
  echo "NOT OK - selfauth: clear_rolled_back_pending: should lift the hold"; fail=1
else
  echo "ok - selfauth: clear_rolled_back_pending: lifts the hold after a successful deploy"
fi

path1="$(rolled_back_state_path)"
path2="$(XDG_STATE_HOME=/tmp/selfauth-xdg-state rolled_back_state_path)"
assert_eq "$path2" "/tmp/selfauth-xdg-state/vibeloop/rolled-back-last-pass" \
  "rolled_back_state_path: honors XDG_STATE_HOME"
case "$path1" in
  */vibeloop/rolled-back-last-pass) echo "ok - selfauth: rolled_back_state_path: default path ends in vibeloop/rolled-back-last-pass" ;;
  *) echo "NOT OK - selfauth: rolled_back_state_path: default path shape wrong: $path1"; fail=1 ;;
esac

# -- AC2/AC3: the ledger field string + the literal digest phrase -----------

fields="$(deploy_ledger_fields deployed none aaa1111..bbb2222 bbb2222)"
assert_eq "$fields" 'deploy_outcome=deployed deploy_cause=none deploy_range=aaa1111..bbb2222 deployed_sha=bbb2222 deploy_summary="deployed aaa1111..bbb2222"' \
  "deploy_ledger_fields: full key=value string for a deployed outcome"
case "$fields" in
  *"deployed aaa1111..bbb2222"*) echo "ok - selfauth: deploy_ledger_fields: digest line contains the literal phrase 'deployed aaa1111..bbb2222'" ;;
  *) echo "NOT OK - selfauth: deploy_ledger_fields: digest phrase missing from '$fields'"; fail=1 ;;
esac

fields_rb="$(deploy_ledger_fields rolled-back migrate-failed aaa1111..bbb2222 aaa1111)"
case "$fields_rb" in
  *"rolled-back aaa1111..bbb2222"*) echo "ok - selfauth: deploy_ledger_fields: digest line contains the literal phrase 'rolled-back aaa1111..bbb2222'" ;;
  *) echo "NOT OK - selfauth: deploy_ledger_fields: digest phrase missing from '$fields_rb'"; fail=1 ;;
esac

# -- AC3/AC7: measure.json gains the four structured fields, existing keys kept --

mj="$(mktemp)"
printf '{"satisfaction": 0.8, "sessions": 3}\n' > "$mj"
merge_deploy_fields_json "$mj" rolled-back migrate-failed aaa1111..bbb2222 aaa1111
assert_eq "$(python3 -c "import json;d=json.load(open('$mj'));print(d['satisfaction'], d['sessions'], d['deploy_outcome'], d['deploy_cause'], d['deploy_range'], d['deployed_sha'])")" \
  "0.8 3 rolled-back migrate-failed aaa1111..bbb2222 aaa1111" \
  "merge_deploy_fields_json: adds the four deploy_* fields, leaves existing keys untouched"
rm -f "$mj"

if [ "$fail" -eq 0 ]; then
  echo "all selfauth_guards tests passed"
else
  echo "selfauth_guards tests FAILED"
fi
exit "$fail"
