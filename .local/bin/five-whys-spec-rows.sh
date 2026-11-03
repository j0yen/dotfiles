#!/usr/bin/env bash
# five-whys-spec-rows: every numbered Mechanisms line that carries `state SPEC` names at least one row id that exists
# in open-asks.tsv (A/M/P rows) or the wm-decide ledger (d-... ids); a SPEC mechanism with no row has no owner clock
# (A684, 11-03 ryzen7 root-fill page, Fable edit 6). Called by the 5whysandrhyme lint-page.sh and the aide sweep.
# Usage: five-whys-spec-rows.sh [--ledger <open-asks.tsv>] [--followups <file holding d-ids>] <page>...
# Exit 0 = every SPEC line rowed (or no SPEC lines), 1 = a SPEC line names no existing row, 2 = usage.
set -uo pipefail
LEDGER="${FIVE_WHYS_LEDGER:-$HOME/.cache/aide/open-asks.tsv}"
FU="${FIVE_WHYS_FOLLOWUPS:-}"
DB="${FIVE_WHYS_DB:-$HOME/.local/state/swarm-decide/decisions.sqlite}"
while [ $# -gt 0 ]; do
  case "$1" in
    --ledger) LEDGER="$2"; shift 2 ;;
    --followups) FU="$2"; shift 2 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    --) shift; break ;;
    -*) echo "five-whys-spec-rows: unknown flag $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
[ $# -ge 1 ] || { echo "usage: five-whys-spec-rows.sh [--ledger tsv] [--followups file] <page>..." >&2; exit 2; }
ids="$(mktemp)"; trap 'rm -f "$ids"' EXIT
[ -r "$LEDGER" ] && awk -F'\t' '$1 ~ /^[AMP][0-9]+$/ {print $1}' "$LEDGER" >> "$ids"
if [ -n "$FU" ]; then
  [ -r "$FU" ] && grep -oE 'd-[0-9]{8}-[0-9]{6}-[A-Za-z0-9:_-]+' "$FU" >> "$ids"
elif [ -r "$DB" ] && command -v sqlite3 >/dev/null 2>&1; then
  sqlite3 -readonly "$DB" 'select id from decisions' 2>/dev/null >> "$ids"
fi
rc=0
for page in "$@"; do
  [ -r "$page" ] || { echo "FAIL $page: unreadable"; rc=1; continue; }
  n=0; bad=0
  while IFS= read -r m; do
    n=$((n+1))
    hit=0
    for id in $(printf '%s\n' "$m" | grep -oE '(^|[^A-Za-z0-9_])([AMP][0-9]+|d-[0-9]{8}-[0-9]{6}-[A-Za-z0-9:_-]+)' | sed -E 's/^[^A-Za-z0-9_]//'); do
      grep -qxF "$id" "$ids" && { hit=1; break; }
    done
    [ "$hit" = 1 ] || { echo "FAIL $page: SPEC mechanism without a row: ${m:0:90}"; bad=1; }
  done < <(awk '/^# Mechanisms/{f=1;next} /^# /{f=0} f&&/^[0-9]+\. /' "$page" | grep -iE 'state[ =:]*(`)?SPEC')
  [ "$bad" = 0 ] && echo "PASS $page: $n SPEC mechanism line(s) rowed" || rc=1
done
exit "$rc"
