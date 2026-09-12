#!/usr/bin/env bash
# tests/ledgerday_ac7_check_corruption.test.sh — PRD-token-ledger-day-buckets
# AC7 (P1, test_prefix: ledgerday): given a corrupted ledger state with a
# message.id counted in two days (constructed fixture), when `token-ledger
# --check` runs, then it exits non-zero naming the date pair. Run with:
#   bash tests/ledgerday_ac7_check_corruption.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ledgerday_test_helpers.sh
. "$here/ledgerday_test_helpers.sh"

ledgerday_setup
cp "$FIXTURES/corrupt-ledger.tsv" "$state/ledger.tsv"
cp "$FIXTURES/corrupt-message-index.tsv" "$state/message-index.tsv"

out="$("$TL" --check 2>&1)"
rc=$?

assert "[ $rc -ne 0 ]" "--check exits non-zero on a corrupted ledger"
assert_contains "$out" "msg_x" "output names the offending message id"
assert_contains "$out" "2026-09-10" "output names the first day of the pair"
assert_contains "$out" "2026-09-11" "output names the second day of the pair"

# Sanity: a clean ledger (per_model sums match weighted, no id in two days)
# reports ok and exits 0 — the checker isn't just always failing.
ledgerday_setup
cp "$FIXTURES/boundary.jsonl" "$jsonl/boundary.jsonl"
"$TL" --since 2026-09-10T00:00:00Z --until 2026-09-12T00:00:00Z >/dev/null
clean_out="$("$TL" --check)"
clean_rc=$?
assert_eq "$clean_rc" "0" "--check exits 0 on a clean ledger produced by a real run"
assert_contains "$clean_out" "ok" "--check reports ok on a clean ledger"

exit "$fail"
