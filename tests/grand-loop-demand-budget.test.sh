#!/usr/bin/env bash
# The measure budget in grand-loop-demand.sh must leave a 300 s margin under the
# unit's TimeoutStartSec, and the measure calls must actually pass it.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
W="$here/.local/bin/grand-loop-demand.sh"
U="$here/.config/systemd/user/grand-loop-demand.service"
fail=0
budget="$(sed -n 's/^MEASURE_BUDGET_S=\([0-9][0-9]*\)$/\1/p' "$W" | head -1)"
timeout_s="$(sed -n 's/^TimeoutStartSec=\([0-9][0-9]*\)$/\1/p' "$U" | head -1)"
if [ -n "$budget" ] && [ -n "$timeout_s" ]; then echo "ok - parsed MEASURE_BUDGET_S=$budget TimeoutStartSec=$timeout_s"
else echo "NOT OK - could not parse budget ('$budget') or timeout ('$timeout_s')"; exit 1; fi
if [ $((budget + 300)) -le "$timeout_s" ]; then echo "ok - budget + 300 ($((budget + 300))) <= TimeoutStartSec ($timeout_s)"
else echo "NOT OK - budget + 300 ($((budget + 300))) > TimeoutStartSec ($timeout_s)"; fail=1; fi
n="$(grep -v '^[[:space:]]*#' "$W" | grep -c -- 'measure .*--budget-seconds "\$MEASURE_BUDGET_S"')"
if [ "$n" -eq 2 ]; then echo "ok - both measure invocations pass --budget-seconds \"\$MEASURE_BUDGET_S\""
else echo "NOT OK - expected 2 measure calls with --budget-seconds, found $n"; fail=1; fi
exit $fail
