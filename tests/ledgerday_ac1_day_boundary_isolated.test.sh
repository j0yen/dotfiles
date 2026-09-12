#!/usr/bin/env bash
# tests/ledgerday_ac1_day_boundary_isolated.test.sh — PRD-token-ledger-day-buckets
# AC1 (P0, test_prefix: ledgerday): given a fixture JSONL with records at
# 2026-09-10T23:59:30Z and 2026-09-11T00:00:30Z, when `token-ledger --since
# 2026-09-10T00:00:00Z --until 2026-09-12T00:00:00Z` runs, then ledger.tsv
# has one row for 2026-09-10 and one for 2026-09-11, each containing only
# its own record's weighted value. Run with:
#   bash tests/ledgerday_ac1_day_boundary_isolated.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ledgerday_test_helpers.sh
. "$here/ledgerday_test_helpers.sh"

ledgerday_setup
cp "$FIXTURES/boundary.jsonl" "$jsonl/boundary.jsonl"

"$TL" --since 2026-09-10T00:00:00Z --until 2026-09-12T00:00:00Z
rc=$?
assert_eq "$rc" "0" "run exits 0"

# msg_b1: in=1 out=1 -> weighted 1 + 5*1 = 6 (day 2026-09-10 only)
# msg_b2: in=2 out=1 -> weighted 2 + 5*1 = 7 (day 2026-09-11 only)
assert_eq "$(ledger_field 2026-09-10 3)" "6" "2026-09-10 row carries only msg_b1's weighted value"
assert_eq "$(ledger_field 2026-09-11 3)" "7" "2026-09-11 row carries only msg_b2's weighted value"

nrows="$(tail -n +2 "$state/ledger.tsv" | wc -l)"
assert_eq "$nrows" "2" "exactly two day rows, no bleed across the boundary"

exit "$fail"
