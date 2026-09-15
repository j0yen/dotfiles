#!/usr/bin/env bash
# summa-lookups-report.sh — manual report, not wired into any hook.
#
# Reads SUMMA_LEDGER (default ~/.cache/summa/lookups.jsonl) and prints
# hit/miss counts, hit rate, and the top 10 keywords from miss lines —
# i.e. what the wiki doesn't cover yet, ranked by how often it's asked.
#
# Usage: summa-lookups-report.sh [days]   (default 7)

set -uo pipefail

DAYS="${1:-7}"
SUMMA_LEDGER="${SUMMA_LEDGER:-$HOME/.cache/summa/lookups.jsonl}"

JQ="${JQ:-jq}"
command -v "$JQ" >/dev/null 2>&1 || { echo "jq not found" >&2; exit 1; }

if [ ! -f "$SUMMA_LEDGER" ]; then
    echo "no ledger at $SUMMA_LEDGER"
    exit 0
fi

case "$DAYS" in
    ''|*[!0-9]*) echo "usage: $0 [days]" >&2; exit 2 ;;
esac

cutoff="$(date -u -d "$DAYS days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
[ -n "$cutoff" ] || { echo "could not compute cutoff date" >&2; exit 1; }

"$JQ" -rs --arg cutoff "$cutoff" '
    map(select(.ts >= $cutoff)) as $recent
    | ($recent | map(select(.result=="hit")) | length) as $h
    | ($recent | map(select(.result=="miss")) | length) as $m
    | ($h + $m) as $total
    | "window: last '"$DAYS"' day(s)",
      "hits: \($h)",
      "misses: \($m)",
      "hit rate: \(if $total > 0 then (($h * 100 / $total) | floor) else 0 end)%"
' "$SUMMA_LEDGER"

echo "--- top 10 miss keywords ---"
"$JQ" -rs --arg cutoff "$cutoff" '
    map(select(.ts >= $cutoff and .result=="miss"))
    | map(.keywords[]?)
    | reduce .[] as $k ({}; .[$k] = (.[$k] // 0) + 1)
    | to_entries
    | sort_by(-.value)
    | .[0:10][]
    | "\(.value)\t\(.key)"
' "$SUMMA_LEDGER"

exit 0
