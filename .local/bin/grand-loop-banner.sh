#!/usr/bin/env bash
# grand-loop-banner.sh — PRD-grand-loop-liveness-contract Requirement 3: one
# line at SessionStart on every node showing the grand loop's liveness (age
# vs GRAND_LOOP_MAX_AGE, the last row's family/reason, the demand alarm
# streak). RED when stale, stuck, or the demand alarm streak is >= 2; OK
# otherwise. Reads only GRAND_LOOP_PRD_DIR/grand-loop/ — no build-skill
# dependency at runtime, no mcphost-deploy call, no git. A RED verdict
# (stale/stuck) also delivers one alert per UTC day via alert-deliver.sh
# when present on PATH (Requirement 6, dedupe by date).
#
# Migration: an existing state.json with no state/last-success.json yet
# reads as `never` (RED) until the loop's first success under this
# contract — that's expected on a fresh install, not a bug.
set -uo pipefail
export PATH="$PATH:$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/grand-loop-lib.sh
. "$HERE/../lib/grand-loop-lib.sh"
# shellcheck source=../lib/grand-loop-demand-lib.sh
. "$HERE/../lib/grand-loop-demand-lib.sh"

PRD_DIR="${GRAND_LOOP_PRD_DIR:-$HOME/Documents/PRDs}"
LOOP_DIR="$PRD_DIR/grand-loop"
STATE="$LOOP_DIR/state.json"
SUCCESS="$LOOP_DIR/state/last-success.json"
LEDGER="$LOOP_DIR/ledger.md"
DEMAND_LEDGER="$LOOP_DIR/demand/ledger.jsonl"

ENV_FILE="${GRAND_LOOP_ENV:-$HOME/.config/grand-loop/env}"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

max_age="${GRAND_LOOP_MAX_AGE:-26h}"

verdict="$(bl_liveness "$STATE" "$SUCCESS")"

color=OK
age_clause=""
case "$verdict" in
  ok)
    age_clause="$(bl_age_human "$(python3 -c "import json;print(json.load(open('$SUCCESS')).get('ts',''))" 2>/dev/null)") ago"
    ;;
  stale)
    color=RED
    age_clause="$(bl_age_human "$(python3 -c "import json;print(json.load(open('$SUCCESS')).get('ts',''))" 2>/dev/null)") ago"
    ;;
  stuck)
    color=RED
    age_clause="$(bl_age_human "$(python3 -c "import json;print((json.load(open('$STATE')).get('phases') or {}).get('PREFLIGHT',{}).get('stamp',''))" 2>/dev/null)") ago"
    ;;
  *)
    color=RED
    age_clause="never"
    ;;
esac

family="-"; reason="-"
last_line="$(last_ledger_line "$LEDGER")"
if [ -n "$last_line" ]; then
  family="$(ledger_field "$last_line" family)"
  reason="$(ledger_field "$last_line" reason)"
  [ -n "$family" ] || family="-"
  [ -n "$reason" ] || reason="-"
fi

streak="$(consecutive_alarm_count "$DEMAND_LEDGER")"
if [ "${streak:-0}" -ge 2 ] 2>/dev/null; then
  color=RED
fi

echo "grand-loop: last measure ${age_clause} (max ${max_age}) — ${color}, family=${family} reason=${reason} demand_alarm_streak=${streak:-0}"

if [ "$color" = RED ] && { [ "$verdict" = "stale" ] || [ "$verdict" = "stuck" ]; }; then
  bl_deliver_stale_alert "$LOOP_DIR" "$verdict" "${age_clause} (max ${max_age})"
fi
