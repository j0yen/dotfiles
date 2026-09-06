#!/usr/bin/env bash
# tests/loop_ac13_daily_section.test.sh — PRD-grand-loop-scaffold AC13: given
# a daily page from buildloop-operations (vibeloop's own vibeloop/digest/<date>.md)
# exists for today, the tick's DIGEST phase appends a `## grand-loop` section
# to it, once, with the day's ledger lines and the open needs; when no such
# page exists, the tick writes its own standalone grand-loop/daily/<date>.md
# instead.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=loop_test_helpers.sh
. "$here/loop_test_helpers.sh"

loop_setup
today="$(date -u +%F)"
mkdir -p "$loop_dir"
echo "slug: foo status: live" > "$loop_dir/candidates.yaml"  # keep discovery from preempting

# --- scenario A: no vibeloop daily digest page for today -> standalone file ---
export FAKE_PROBE_MODE=ok FAKE_MEASURE_MODE=ok
export FAKE_MEASURE_JSON='{"deployed_version":"0.1.0","billing_mode":"off","real_tenants":4,"paying_tenants":0,"paid_mrr_usd":0}'
run_tick > /dev/null

standalone="$loop_dir/daily/$today.md"
[ -f "$standalone" ]; assert_eq "$?" "0" "standalone daily page created when no vibeloop digest page exists"
section_count_a="$(grep -c '^## grand-loop$' "$standalone" 2>/dev/null || echo 0)"
assert_eq "$section_count_a" "1" "standalone page carries exactly one ## grand-loop section"
assert_contains "$(cat "$standalone")" "PUBLISH-OK absent" "open needs flag PUBLISH-OK absent when the file is missing"
assert_contains "$(cat "$standalone")" "billing off" "open needs flag billing off when billing_mode != live"

# --- scenario B: a vibeloop daily digest page exists for today -> section goes there ---
vibeloop_page="$repo/vibeloop/digest/$today.md"
mkdir -p "$(dirname "$vibeloop_page")"
printf '# vibeloop daily digest — %s\n\n## Needs you\n\n- none\n' "$today" > "$vibeloop_page"
touch "$loop_dir/PUBLISH-OK"

export FAKE_MEASURE_JSON='{"deployed_version":"0.1.0","billing_mode":"live","real_tenants":10,"new_real_tenants":0,"real_wow_rate":0.5,"paying_tenants":5,"paid_mrr_usd":58,"gross_churn":0.02}'
run_tick > /dev/null

section_count_b="$(grep -c '^## grand-loop$' "$vibeloop_page" 2>/dev/null || echo 0)"
assert_eq "$section_count_b" "1" "vibeloop digest page gets exactly one ## grand-loop section"
assert_contains "$(cat "$vibeloop_page")" "## Needs you" "vibeloop digest page's own sections are left intact"
assert_contains "$(cat "$vibeloop_page")" "paid_mrr_usd=58" "the grand-loop section carries today's ledger line"
assert_not_contains "$(cat "$vibeloop_page")" "PUBLISH-OK absent" "PUBLISH-OK now present so that need clears"

# A second tick the same day must replace the section, not add a second one.
export FAKE_MEASURE_JSON='{"deployed_version":"0.1.0","billing_mode":"live","real_tenants":11,"new_real_tenants":1,"real_wow_rate":0.5,"paying_tenants":5,"paid_mrr_usd":61,"gross_churn":0.02}'
run_tick > /dev/null

section_count_c="$(grep -c '^## grand-loop$' "$vibeloop_page" 2>/dev/null || echo 0)"
assert_eq "$section_count_c" "1" "a second same-day tick still leaves exactly one ## grand-loop section"
assert_contains "$(cat "$vibeloop_page")" "paid_mrr_usd=61" "the section was replaced with the latest ledger line"

exit $fail
