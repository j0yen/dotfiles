#!/usr/bin/env bash
# tests/ledgerday_ac8_selftest_suite_green.test.sh — PRD-token-ledger-day-buckets
# AC8 (P1, test_prefix: ledgerday): given the selftest fixture set, when the
# dotfiles selftest runs, then the ledgerday cases are named and green.
# Operationalized here as: every sibling ledgerday_ac{1..7} test file runs
# clean (exit 0, no "NOT OK" lines) when invoked the same way the dotfiles
# test sweep invokes any *.test.sh file — `bash <file>` from the repo root.
# Run with:
#   bash tests/ledgerday_ac8_selftest_suite_green.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ledgerday_test_helpers.sh
. "$here/ledgerday_test_helpers.sh"

siblings=()
for f in "$here"/ledgerday_ac*.test.sh; do
  base="$(basename "$f")"
  [ "$base" = "$(basename "${BASH_SOURCE[0]}")" ] && continue
  siblings+=("$f")
done

assert_eq "${#siblings[@]}" "7" "seven other ledgerday_ac* cases are present (AC1-7)"

for f in "${siblings[@]}"; do
  base="$(basename "$f")"
  out="$(bash "$f" 2>&1)"
  rc=$?
  assert_eq "$rc" "0" "$base exits 0"
  assert_not_contains "$out" "NOT OK" "$base reports no failing assertions"
done

exit "$fail"
