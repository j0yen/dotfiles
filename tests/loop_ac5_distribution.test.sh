#!/usr/bin/env bash
# tests/loop_ac5_distribution.test.sh — PRD-grand-loop-scaffold AC5: given a
# ledger showing listings live for 15 days and new_real_tenants 0 across
# those lines, the tick classifies `distribution` and the loop note carries
# the family's standing instruction. Also covers the two ways the family
# must NOT fire (listings not live long enough; real growth in the window)
# and that PREFLIGHT itself stamps listings_live_since on first observation.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=loop_test_helpers.sh
. "$here/loop_test_helpers.sh"

iso_days_ago() {
  python3 -c "
from datetime import datetime, timezone, timedelta
print((datetime.now(timezone.utc) - timedelta(days=int('$1'))).strftime('%Y-%m-%dT%H:%M:%SZ'))
"
}

seed_listings_since() { # $1=state.json $2=days_ago
  python3 -c "
import json
json.dump({'listings_live_since': '$(iso_days_ago "$2")'}, open('$1', 'w'))
"
}

seed_ledger_line() { # $1=ledger $2=days_ago $3=new_real_tenants
  local ledger="$1" days="$2" nrt="$3" stamp
  stamp="$(iso_days_ago "$days")"
  printf '%s version=0.1.0 billing_mode=off real_tenants=4 new_real_tenants=%s real_wow_rate=0.1 paying_tenants=0 paid_mrr_usd=0 gross_churn=- exclusions=- family=flat reason="prior tick" reached_measure=1\n' \
    "$stamp" "$nrt" >> "$ledger"
}

# -- positive: listings live 15 days, no growth anywhere in the window ------
loop_setup
mkdir -p "$loop_dir"
seed_listings_since "$state" 15
for d in 12 8 3; do seed_ledger_line "$ledger" "$d" 0; done

export FAKE_PROBE_MODE=ok FAKE_MEASURE_MODE=ok
export FAKE_LISTINGS_JSON='{"live": true}'
export FAKE_MEASURE_JSON='{"deployed_version":"0.1.0","billing_mode":"off","real_tenants":4,"new_real_tenants":0,"real_wow_rate":0.1,"paying_tenants":0,"paid_mrr_usd":0}'
run_tick > /dev/null
line="$(tail -n1 "$ledger")"
assert_contains "$line" "family=distribution" "distribution: listings live 15 days, no growth in the window"
assert_contains "$(cat "$profile")" "draft a listings or channel PRD, not a feature" "loop note carries the distribution instruction"

# -- negative: listings live only 5 days -> not distribution ----------------
loop_setup
mkdir -p "$loop_dir"
seed_listings_since "$state" 5
for d in 3 1; do seed_ledger_line "$ledger" "$d" 0; done
export FAKE_PROBE_MODE=ok FAKE_MEASURE_MODE=ok
export FAKE_LISTINGS_JSON='{"live": true}'
export FAKE_MEASURE_JSON='{"deployed_version":"0.1.0","billing_mode":"off","real_tenants":4,"new_real_tenants":0,"real_wow_rate":0.1,"paying_tenants":0,"paid_mrr_usd":0}'
run_tick > /dev/null
line="$(tail -n1 "$ledger")"
assert_not_contains "$line" "family=distribution" "distribution: listings live only 5 days -> not distribution"

# -- negative: listings live 15 days but real growth in the window ----------
loop_setup
mkdir -p "$loop_dir"
seed_listings_since "$state" 15
seed_ledger_line "$ledger" 10 0
seed_ledger_line "$ledger" 5 3   # growth inside the 14-day window
export FAKE_PROBE_MODE=ok FAKE_MEASURE_MODE=ok
export FAKE_LISTINGS_JSON='{"live": true}'
export FAKE_MEASURE_JSON='{"deployed_version":"0.1.0","billing_mode":"off","real_tenants":4,"new_real_tenants":0,"real_wow_rate":0.1,"paying_tenants":0,"paid_mrr_usd":0}'
run_tick > /dev/null
line="$(tail -n1 "$ledger")"
assert_not_contains "$line" "family=distribution" "distribution: growth inside the window blocks the family"

# -- PREFLIGHT stamps listings_live_since on first "live" observation -------
loop_setup
export FAKE_PROBE_MODE=ok FAKE_MEASURE_MODE=ok
export FAKE_LISTINGS_JSON='{"live": true}'
export FAKE_MEASURE_JSON='{"deployed_version":"0.1.0","billing_mode":"off","real_tenants":4,"new_real_tenants":1,"real_wow_rate":0.1,"paying_tenants":0,"paid_mrr_usd":0}'
run_tick > /dev/null
since="$(python3 -c "import json;print(json.load(open('$state')).get('listings_live_since',''))" 2>/dev/null)"
[ -n "$since" ] && echo "ok - PREFLIGHT stamped listings_live_since on first live observation" || { echo "NOT OK - listings_live_since not stamped"; fail=1; }

# -- listings.live: false resets the stamp -----------------------------------
loop_setup
mkdir -p "$loop_dir"
seed_listings_since "$state" 20
export FAKE_PROBE_MODE=ok FAKE_MEASURE_MODE=ok
export FAKE_LISTINGS_JSON='{"live": false}'
export FAKE_MEASURE_JSON='{"deployed_version":"0.1.0","billing_mode":"off","real_tenants":4,"new_real_tenants":0,"real_wow_rate":0.1,"paying_tenants":0,"paid_mrr_usd":0}'
run_tick > /dev/null
since2="$(python3 -c "import json;print(json.load(open('$state')).get('listings_live_since') or '')" 2>/dev/null)"
[ -z "$since2" ] && echo "ok - listings.live:false resets listings_live_since" || { echo "NOT OK - listings_live_since not reset: got '$since2'"; fail=1; }
line="$(tail -n1 "$ledger")"
assert_not_contains "$line" "family=distribution" "distribution: freshly-reset stamp is not >=14 days"

exit $fail
