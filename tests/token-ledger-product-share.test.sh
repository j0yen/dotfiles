#!/usr/bin/env bash
# tests/token-ledger-product-share.test.sh — build-share.json carries product_share
# (inner|chain|live weighted / share denominator), product_weighted, product_roles_re
# and product_alarm (share < 40 % with denominator > 50M). A33.
# Run with: bash tests/token-ledger-product-share.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ledgerday_test_helpers.sh
. "$here/ledgerday_test_helpers.sh"

ledgerday_setup
export SEATS_TABLE="$work/seats.tsv"
printf '# seat\trole\tsid\ttick_min\n\nrb\tr\tsid-rb\t5\n' > "$SEATS_TABLE"
export TOKEN_LEDGER_AIDE_SIDS="$work/aide-sids"
printf '# aide session ids\n' > "$TOKEN_LEDGER_AIDE_SIDS"
asst() { printf '{"type":"assistant","timestamp":"2026-09-12T09:00:00Z","message":{"id":"%s","model":"m","usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}\n' "$1" "$2"; }
user_str() { printf '{"type":"user","uuid":"u-%s","timestamp":"2026-09-12T08:59:00Z","message":{"content":"%s"}}\n' "$RANDOM" "$1"; }
mk() { mkdir -p "$(dirname "$jsonl/$1")"; { user_str "$2"; asst "m-$(echo "$1" | tr -c 'a-z0-9\n' '-')" "$3"; } > "$jsonl/$1"; }

# --- 1. inner 20M, seat:rb 80M (build 100M of 100M, product 20 %) -> alarm ---
rm -rf "$jsonl" "$state"/*; mkdir -p "$jsonl"
mk "-home-jsy-wm-build-wt-foo/inner1.jsonl" "hello" 20000000
mk "-home-jsy/sid-rb.jsonl" "implement the thing" 80000000
"$TL"
bs="$state/build-share.json"
assert_eq "$(jq -r '.product_share' "$bs")" "20.0" "product_share = inner / denominator"
assert_eq "$(jq -r '.product_weighted' "$bs")" "20000000" "product_weighted"
assert_eq "$(jq -r '.product_roles_re' "$bs")" '^(inner|chain|live)$' "product role set named"
assert_eq "$(jq -r '.product_alarm' "$bs")" "true" "20 % of 100M alarms"

# --- 2. inner 70M, seat:rb 30M -> 70 %, no alarm ---
rm -rf "$jsonl" "$state"/*; mkdir -p "$jsonl"
mk "-home-jsy-wm-build-wt-foo/inner1.jsonl" "hello" 70000000
mk "-home-jsy/sid-rb.jsonl" "implement the thing" 30000000
"$TL"
assert_eq "$(jq -r '.product_share' "$bs")" "70.0" "product_share 70"
assert_eq "$(jq -r '.product_alarm' "$bs")" "false" "70 % does not alarm"

# --- 3. small day (denominator <= 50M): share reported, no alarm ---
rm -rf "$jsonl" "$state"/*; mkdir -p "$jsonl"
mk "-home-jsy-wm-build-wt-foo/inner1.jsonl" "hello" 1000000
mk "-home-jsy/sid-rb.jsonl" "implement the thing" 9000000
"$TL"
assert_eq "$(jq -r '.product_share' "$bs")" "10.0" "small day share"
assert_eq "$(jq -r '.product_alarm' "$bs")" "false" "small day never alarms"

# --- 4. summary file is untouched by the product alarm ---
assert_not_contains "$(cat "$state/today-summary.txt")" "product" "summary line unchanged"
exit "$fail"
