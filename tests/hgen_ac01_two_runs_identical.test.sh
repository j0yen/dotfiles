#!/usr/bin/env bash
# PRD dotfiles-handoff-generated AC1: with status.json, a state.db holding 2
# ended runs and a 2-row chain ledger, two runs of `handoff-gen.sh --out t.md`
# give outputs <= 80 lines that carry all 8 sections with sources and differ
# only in the `Generated` line.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/hgen_test_helpers.sh"
hgen_setup
a="$work/a.md"; b="$work/b.md"
"$HGEN" --out "$a"; assert_eq "$?" "0" "first run exits 0"
sleep 1
"$HGEN" --out "$b"; assert_eq "$?" "0" "second run exits 0"
assert_eq "$([ "$(wc -l <"$a")" -le 80 ] && echo yes)" "yes" "<= 80 lines"
for s in Generated Runs Queue "Decisions open" Versions Chain "Sessions alive" Config; do
  grep -qE "^## $s \(.+\)$" "$a" && echo "ok - section '$s' has a source" || { echo "NOT OK - section '$s' missing or unsourced"; fail=1; }
done
assert_eq "$(grep -c '^## ' "$a")" "8" "exactly 8 sections"
assert_eq "$(diff <(grep -v '^Generated:' "$a") <(grep -v '^Generated:' "$b") | wc -l)" "0" "outputs differ only in the Generated line"
assert_eq "$(grep -c '^Generated:' "$a")" "1" "one Generated line"
assert_contains "$(cat "$a")" "ended 24h: 602 ended-b outcome=Code cause=op-close" "ended run with outcome + close_cause"
assert_contains "$(cat "$a")" "ended 24h: 601 ended-a outcome=Landed cause=landed" "second ended run"
assert_contains "$(cat "$a")" "open: 488 alpha land" "open run from status.json"
assert_contains "$(cat "$a")" "newest: c2 digest running" "newest chain row"
assert_contains "$(cat "$a")" "queue: 12 (building 2, ready 5, blocked 3, parked 2)" "queue counts from fleet-dash"
# a stale queue source prints unknown, never a number
jq '.sources.queue="stale"' "$work/cache/status.json" >"$work/stale.json" && cp "$work/stale.json" "$work/cache/status.json"
"$HGEN" --out "$work/c.md"
assert_contains "$(cat "$work/c.md")" "queue: unknown (stale)" "stale queue source -> unknown"
assert_eq "$(grep -c 'queue: 12' "$work/c.md")" "0" "stale source prints no number"
assert_eq "$(ls "$work" | grep -c 'tmp')" "0" "no temp file left"
exit $fail
