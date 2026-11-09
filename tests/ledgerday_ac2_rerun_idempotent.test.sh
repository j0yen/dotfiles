#!/usr/bin/env bash
# tests/ledgerday_ac2_rerun_idempotent.test.sh — PRD-token-ledger-day-buckets
# AC2 (P0, test_prefix: ledgerday): given the same fixture as AC1, when the
# command runs twice, then ledger.tsv is byte-identical after the second
# run and has no duplicate dates. Run with:
#   bash tests/ledgerday_ac2_rerun_idempotent.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ledgerday_test_helpers.sh
. "$here/ledgerday_test_helpers.sh"

ledgerday_setup
cp "$FIXTURES/boundary.jsonl" "$jsonl/boundary.jsonl"

"$TL" --since 2026-09-10T00:00:00Z --until 2026-09-12T00:00:00Z
first="$(cat "$state/ledger.tsv")"

"$TL" --since 2026-09-10T00:00:00Z --until 2026-09-12T00:00:00Z
rc=$?
second="$(cat "$state/ledger.tsv")"

assert_eq "$rc" "0" "second run exits 0"
assert_eq "$second" "$first" "ledger.tsv is byte-identical after a rerun"

dates="$(tail -n +2 "$state/ledger.tsv" | cut -f1)"
uniq_dates="$(echo "$dates" | sort -u)"
assert_eq "$dates" "$uniq_dates" "no duplicate dates after the rerun"

exit "$fail"
