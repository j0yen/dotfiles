#!/usr/bin/env bash
# tests/liveness_ac07_success_stamp_and_banner_ok.test.sh —
# PRD-grand-loop-liveness-contract AC7: a successful tick (reaches DIGEST
# ok) writes state/last-success.json, and grand-loop-banner.sh then prints
# OK with age under 1h.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=loop_test_helpers.sh
. "$here/loop_test_helpers.sh"
BANNER="$(cd "$here/.." && pwd)/.local/bin/grand-loop-banner.sh"

loop_setup

export FAKE_PROBE_MODE=ok
export FAKE_MEASURE_MODE=ok
export FAKE_MEASURE_JSON='{"deployed_version":"1.2.3","billing_mode":"off","real_tenants":4,"new_real_tenants":1,"real_wow_rate":0.2,"paying_tenants":0,"paid_mrr_usd":0,"gross_churn":null,"exclusions":{"harness_prefix":3}}'

run_tick >/dev/null

success_file="$loop_dir/state/last-success.json"
[ -f "$success_file" ]; assert_eq "$?" "0" "state/last-success.json was written on a successful tick"

phase="$(python3 -c "import json;print(json.load(open('$success_file')).get('phase'))" 2>/dev/null)"
version="$(python3 -c "import json;print(json.load(open('$success_file')).get('version'))" 2>/dev/null)"
assert_eq "$phase" "DIGEST" "last-success.json records phase=DIGEST"
assert_eq "$version" "1.2.3" "last-success.json records the deployed_version from measure.json"

ts="$(python3 -c "import json;print(json.load(open('$success_file')).get('ts',''))" 2>/dev/null)"
age_secs="$(python3 -c "
from datetime import datetime, timezone
dt = datetime.strptime('$ts', '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)
print((datetime.now(timezone.utc) - dt).total_seconds())
" 2>/dev/null)"
python3 -c "import sys; sys.exit(0 if float('$age_secs') < 3600 else 1)"
assert_eq "$?" "0" "last-success.json's ts is under 1h old"

out="$(GRAND_LOOP_PRD_DIR="$repo" GRAND_LOOP_ENV="$work/nonexistent-env" bash "$BANNER")"
line="$(printf '%s\n' "$out" | grep '^grand-loop:' || true)"
assert_contains "$line" "OK" "banner reports OK for a fresh success row"
assert_not_contains "$line" "RED" "banner does not report RED for a fresh success row"
assert_contains "$line" "min" "banner's age for a just-succeeded tick is reported in minutes, not hours"

exit $fail
