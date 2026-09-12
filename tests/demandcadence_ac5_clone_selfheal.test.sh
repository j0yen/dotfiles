#!/usr/bin/env bash
# tests/demandcadence_ac5_clone_selfheal.test.sh — PRD-grand-loop-demand-cadence
# AC5: an absent dedicated clone is cloned and the run proceeds; a clone
# that has diverged from origin is reset to origin and the row notes it.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=demandcadence_test_helpers.sh
. "$here/demandcadence_test_helpers.sh"
demandcadence_setup

export FAKE_MEASURE_MODE=ok
export FAKE_MEASURE_JSON='{"paid_mrr_usd":0,"paying_tenants":0,"real_tenants":1,"real_wow_rate":0.1,"gross_churn":null,"validated":false}'

[ ! -e "$clone" ] || { echo "NOT OK - clone absent precondition"; fail=1; }
export GRAND_LOOP_DEMAND_TODAY=2026-09-13
run_demand run >/dev/null
[ -d "$clone/.git" ] && echo "ok - absent clone: cloned and proceeded" || { echo "NOT OK - clone was not created"; fail=1; }
line1="$(tail -n1 "$ledger")"
assert_contains "$line1" "\"clone_state\":\"cloned\"" "absent-clone row notes clone_state=cloned"

# Diverge origin: a second, independent clone pushes a commit our clone has
# never seen (our $clone is now behind/diverged from origin's main).
other="$work/other-clone"
git clone -q --branch main "$origin_bare" "$other" >/dev/null 2>&1
git -C "$other" config user.email test@test.com
git -C "$other" config user.name test
printf 'x\n' > "$other/other.md"
git -C "$other" add -A && git -C "$other" commit -q -m "external change"
git -C "$other" push -q origin main

export GRAND_LOOP_DEMAND_TODAY=2026-09-14
run_demand run >/dev/null

[ -f "$clone/other.md" ] && echo "ok - diverged clone: reset to origin (other.md now present)" \
  || { echo "NOT OK - diverged clone was not reset to origin"; fail=1; }
line2="$(tail -n1 "$ledger")"
assert_contains "$line2" "\"clone_state\":\"reset\"" "diverged-clone row notes clone_state=reset"

exit $fail
