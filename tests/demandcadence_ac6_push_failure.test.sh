#!/usr/bin/env bash
# tests/demandcadence_ac6_push_failure.test.sh — PRD-grand-loop-demand-cadence
# AC6: a push failure (fake remote refuses) leaves the row locally with a
# push-failed warning; the next successful run pushes both.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=demandcadence_test_helpers.sh
. "$here/demandcadence_test_helpers.sh"
demandcadence_setup

export FAKE_MEASURE_MODE=ok

export GRAND_LOOP_DEMAND_TODAY=2026-09-13
export FAKE_MEASURE_JSON='{"paid_mrr_usd":0,"paying_tenants":0,"real_tenants":1,"real_wow_rate":0.1,"gross_churn":null,"validated":false}'
run_demand run >/dev/null   # clean clone+push, establishes the clone

# Make the remote refuse writes (read still works — fetch/clone stay fine).
chmod -R a-w "$origin_bare"

export GRAND_LOOP_DEMAND_TODAY=2026-09-14
export FAKE_MEASURE_JSON='{"paid_mrr_usd":19,"paying_tenants":1,"real_tenants":1,"real_wow_rate":0.2,"gross_churn":null,"validated":false}'
run_demand run >/dev/null

line2="$(tail -n1 "$ledger")"
assert_contains "$line2" "\"push\":\"failed\"" "push-failure run: row carries a push-failed warning"
assert_contains "$(cat "$GRAND_LOOP_DEMAND_LOG")" "warn: push failed" "push-failure run: journal warns"

clone_head="$(git -C "$clone" rev-parse HEAD)"
origin_head="$(git -C "$origin_bare" rev-parse main)"
[ "$clone_head" != "$origin_head" ] && echo "ok - the row stayed local (origin unchanged)" \
  || { echo "NOT OK - local and remote HEAD unexpectedly match after a push failure"; fail=1; }

# Restore write access and let the next successful run push both.
chmod -R u+w "$origin_bare"

export GRAND_LOOP_DEMAND_TODAY=2026-09-15
export FAKE_MEASURE_JSON='{"paid_mrr_usd":19,"paying_tenants":1,"real_tenants":1,"real_wow_rate":0.1,"gross_churn":null,"validated":false}'
run_demand run >/dev/null

verify="$work/verify-clone"
git clone -q --branch main "$origin_bare" "$verify" >/dev/null 2>&1
verify_ledger="$verify/grand-loop/demand/ledger.jsonl"
[ -f "$verify_ledger" ] || { echo "NOT OK - verify clone has no ledger"; fail=1; }
vlines="$(wc -l < "$verify_ledger" 2>/dev/null || echo 0)"
# day13 (pushed clean, run 1) + day14 (push-failed, run 2) + day15 (run 3,
# whose successful push carries both its own row AND day14's earlier
# unpushed row+markfail commits through) = 3 rows total once origin catches up.
assert_eq "$vlines" "3" "the next successful push carries the earlier failed-push row and the new one through to origin"
assert_contains "$(cat "$verify_ledger")" "\"push\":\"failed\"" "the previously push-failed row's warning rides along"

exit $fail
