#!/usr/bin/env bash
# tests/loop_ac10_loop_notes.test.sh — PRD-grand-loop-scaffold AC10: after a
# tick completes DIGEST, projects/grand-loop.md carries exactly one
# `## Loop notes` line for today; a second tick the same day replaces it
# rather than adding one.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=loop_test_helpers.sh
. "$here/loop_test_helpers.sh"

loop_setup
today="$(date -u +%F)"
mkdir -p "$loop_dir"
echo "slug: foo status: live" > "$loop_dir/candidates.yaml"  # non-held row: discovery must not preempt growing/flat

export FAKE_PROBE_MODE=ok FAKE_MEASURE_MODE=ok
export FAKE_MEASURE_JSON='{"deployed_version":"0.1.0","billing_mode":"off","real_tenants":4,"paying_tenants":0,"paid_mrr_usd":0}'
run_tick > /dev/null

count1="$(grep -c "^- ${today} (grand-loop):" "$profile")"
assert_eq "$count1" "1" "one dated loop-note line after the first tick"
first_note="$(grep "^- ${today} (grand-loop):" "$profile")"
assert_contains "$first_note" "family=flat" "first note: family=flat (no prior live measure to compare against)"

# Second tick, same UTC day, different measure -> should replace, not add.
export FAKE_MEASURE_JSON='{"deployed_version":"0.1.0","billing_mode":"live","real_tenants":10,"new_real_tenants":0,"real_wow_rate":0.5,"paying_tenants":5,"paid_mrr_usd":58,"gross_churn":0.02}'
run_tick > /dev/null

count2="$(grep -c "^- ${today} (grand-loop):" "$profile")"
assert_eq "$count2" "1" "still exactly one dated loop-note line after the second tick"
second_note="$(grep "^- ${today} (grand-loop):" "$profile")"
assert_contains "$second_note" "paid_mrr_usd=58" "second note replaced the first (paid_mrr_usd=58)"

exit $fail
