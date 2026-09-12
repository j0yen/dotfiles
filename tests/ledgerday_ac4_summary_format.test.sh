#!/usr/bin/env bash
# tests/ledgerday_ac4_summary_format.test.sh — PRD-token-ledger-day-buckets
# AC4 (P0, test_prefix: ledgerday): given `until` inside today, when the run
# completes, then today-summary.txt matches `TOKENS yesterday <date>: <N>
# <status> · today so far <N> (<hh:mm>Z) · forecast <N> · hosts <list>
# missing <list>`, and yesterday's row is complete=yes while today's is
# complete=no. TOKEN_LEDGER_NOW fakes "now" so this is fully hermetic — no
# dependency on wall-clock time. Run with:
#   bash tests/ledgerday_ac4_summary_format.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ledgerday_test_helpers.sh
. "$here/ledgerday_test_helpers.sh"

ledgerday_setup   # TOKEN_LEDGER_NOW=2026-09-12T10:15:00Z (yesterday=09-11, today=09-12)
cp "$FIXTURES/ac4.jsonl" "$jsonl/ac4.jsonl"

"$TL"
rc=$?
assert_eq "$rc" "0" "default run (no explicit --since/--until) exits 0"

summary="$(cat "$state/today-summary.txt")"
# msg_y1 (yesterday, 2026-09-11): in=10 -> weighted 10
# msg_t1 (today, 2026-09-12, 09:00Z): in=20 -> weighted 20
# forecast = 20 * 24 / 10.25h elapsed = 46.83 -> rounds to 47
expected="TOKENS yesterday 2026-09-11: 10 budget off · today so far 20 (10:15Z) · forecast 47 · hosts carbon missing "
assert_eq "$summary" "$expected" "today-summary.txt matches the exact contract format"

assert_eq "$(ledger_field 2026-09-11 5)" "yes" "yesterday's row is complete=yes"
assert_eq "$(ledger_field 2026-09-12 5)" "no" "today's row is complete=no"

exit "$fail"
