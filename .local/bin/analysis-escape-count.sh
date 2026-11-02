#!/usr/bin/env bash
# analysis-escape-count.sh [SINCE] — decision rows that carry root-cause /
# five-whys language without linking a /5whysandrhyme page (Fable review
# 10-24: the weakest link is inline analysis that leaves no trace; this is its
# falsifier). Prints `analysis_escapes=<n> linked=<m> rows=<total> since=<SINCE>`
# then one escaped row id per line (max 20). Baseline 10-24 4:5x PM over 24h:
# 34 escapes, 0 linked, 1591 rows. Read-only.
# `--json [SINCE]` prints one status.json fragment instead:
# {"analysis_escapes":n,"linked":m,"rows":t,"since":..,"alarm":bool,"ids":[..]};
# alarm = escapes >= ESCAPE_ALARM_MIN (default 1); wm-decide failure prints
# {"analysis_escapes":null,"alarm":true,...} (unknown renders as alarm, never a stale number).
# Test hook: WM_DECIDE_JSON=<file> reads rows from a file instead of wm-decide.
set -uo pipefail
JSON=0; [ "${1:-}" = "--json" ] && { JSON=1; shift; }
SINCE=${1:-24h}
if [ -n "${WM_DECIDE_JSON:-}" ]; then ROWS=$(cat "$WM_DECIDE_JSON")
else ROWS=$(wm-decide list --since "$SINCE" --json 2>/dev/null) || {
  if [ "$JSON" = 1 ]; then jq -nc --arg s "$SINCE" '{analysis_escapes:null,linked:null,rows:null,since:$s,alarm:true,ids:[]}'
  else echo "analysis_escapes=unknown (wm-decide failed)"; fi
  exit 1; }
fi
if [ "$JSON" = 1 ]; then
printf '%s' "$ROWS" | jq -c --arg since "$SINCE" --argjson min "${ESCAPE_ALARM_MIN:-1}" '
  def txt: [.what, .why, .evidence] | map(tostring) | join(" ");
  def rc: test("root.?cause|five whys|5 whys|five-whys|post-?mortem"; "i");
  def linked: test("five-whys-rhyme");
  [.[] | {id, t: txt}] as $r
  | ($r | map(select((.t|rc) and (.t|linked|not)))) as $esc
  | {analysis_escapes: ($esc|length), linked: ($r|map(select(.t|linked))|length), rows: ($r|length),
     since: $since, alarm: (($esc|length) >= $min), ids: ($esc[:20] | map(.id))}'
exit 0
fi
printf '%s' "$ROWS" | jq -r --arg since "$SINCE" '
  def txt: [.what, .why, .evidence] | map(tostring) | join(" ");
  def rc: test("root.?cause|five whys|5 whys|five-whys|post-?mortem"; "i");
  def linked: test("five-whys-rhyme");
  [.[] | {id, t: txt}] as $r
  | ($r | map(select((.t|rc) and (.t|linked|not)))) as $esc
  | ($r | map(select(.t|linked))) as $lnk
  | "analysis_escapes=\($esc|length) linked=\($lnk|length) rows=\($r|length) since=\($since)",
    ($esc[:20][] | .id)'
