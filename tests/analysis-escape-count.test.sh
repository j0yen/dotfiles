#!/usr/bin/env bash
# analysis-escape-count.sh: counts root-cause rows without a five-whys-rhyme link.
set -u
H="$(dirname "$0")/../.local/bin/analysis-escape-count.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
printf '%s' '[{"id":"a","what":"root cause was X","why":"","evidence":""},
 {"id":"b","what":"five whys","why":"","evidence":"wiki/answers/2026-10-24-x-five-whys-rhyme.md"},
 {"id":"c","what":"bump limit","why":"Post-mortem pending","evidence":null},
 {"id":"d","what":"set cap","why":"","evidence":""}]' >"$T/rows.json"
out=$(WM_DECIDE_JSON="$T/rows.json" "$H" 24h)
want=$(printf 'analysis_escapes=2 linked=1 rows=4 since=24h\na\nc')
[ "$out" = "$want" ] && { echo "ok escape count"; exit 0; } || { echo "FAIL got: $out"; exit 1; }
