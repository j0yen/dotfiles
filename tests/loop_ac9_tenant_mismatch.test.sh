#!/usr/bin/env bash
# tests/loop_ac9_tenant_mismatch.test.sh — PRD-grand-loop-scaffold AC9: a
# /healthz with tenants_total=47, tenants_probe=3, and a measure with
# real_tenants=4 and exclusions.harness_prefix=39 -> family=instrument,
# reason "tenant accounting mismatch" (47-3=44 != 4+39=43).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=loop_test_helpers.sh
. "$here/loop_test_helpers.sh"

loop_setup
export FAKE_PROBE_MODE=ok
export FAKE_HEALTHZ_JSON='{"db_ok": true, "tenants_total": 47, "tenants_probe": 3}'
export FAKE_MEASURE_MODE=ok
export FAKE_MEASURE_JSON='{"deployed_version":"0.1.0","billing_mode":"off","real_tenants":4,"paying_tenants":0,"paid_mrr_usd":0,"exclusions":{"harness_prefix":39}}'

run_tick > /dev/null
line="$(tail -n1 "$ledger")"
assert_contains "$line" "family=instrument" "mismatch: family=instrument"
assert_contains "$line" "tenant accounting mismatch" "mismatch: reason names the mismatch"

exit $fail
