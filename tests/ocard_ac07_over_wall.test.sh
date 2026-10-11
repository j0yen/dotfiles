#!/usr/bin/env bash
# PRD dotfiles-operator-status-card AC7: a run with age_min 1738 and
# [gate] wall_minutes = 180 in effective_config renders a line ending
# OVER-WALL; runs inside their wall do not.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/ocard_test_helpers.sh"
OC_GATE_WALL=180 ocard_setup
out="$("$CARD")"
echo "$out"
over="$(grep -E '^  488 ' <<<"$out")"
assert_eq "${over##* }" "OVER-WALL" "run 488 (land, 1738m > 180) line ends with OVER-WALL"
assert_contains "$over" "1738m" "the line shows the age"
assert_eq "$(grep -c 'OVER-WALL' <<<"$out")" "1" "only the overdue run is flagged"
sec="$("$CARD" --section runs)"; assert_contains "$sec" "OVER-WALL" "--section runs carries the flag"
assert_eq "$(wc -l <<<"$out" | tr -d ' ')" "$(wc -l <<<"$out" | awk '{print ($1<=25)?$1:"too-long"}')" "card is <= 25 lines"
exit $fail
