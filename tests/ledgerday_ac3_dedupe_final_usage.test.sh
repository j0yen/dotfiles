#!/usr/bin/env bash
# tests/ledgerday_ac3_dedupe_final_usage.test.sh — PRD-token-ledger-day-buckets
# AC3 (P0, test_prefix: ledgerday): given a fixture with three lines sharing
# one message.id and cumulative usage, when bucketed, then that message
# counts once, in the day of its last line, at its final usage (not the
# sum of all three lines, not an earlier line's value). Run with:
#   bash tests/ledgerday_ac3_dedupe_final_usage.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ledgerday_test_helpers.sh
. "$here/ledgerday_test_helpers.sh"

ledgerday_setup
cp "$FIXTURES/dedupe.jsonl" "$jsonl/dedupe.jsonl"

"$TL" --since 2026-09-11T00:00:00Z --until 2026-09-12T00:00:00Z
rc=$?
assert_eq "$rc" "0" "run exits 0"

# Three lines for msg_d1: in=1, in=2, in=100 (final). Final-only weighted = 100.
# Sum-of-all-three would be 103; first-line-only would be 1 — both wrong.
assert_eq "$(ledger_field 2026-09-11 3)" "100" "day row uses msg_d1's final cumulative usage, not the sum or an earlier line"

nrows="$(tail -n +2 "$state/ledger.tsv" | wc -l)"
assert_eq "$nrows" "1" "the message counts once (one row), not three"

exit "$fail"
