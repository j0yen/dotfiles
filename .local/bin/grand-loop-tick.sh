#!/usr/bin/env bash
# grand-loop-tick.sh — PRD-grand-loop-scaffold: the outer loop's one tick.
#
# Runs PREFLIGHT -> MEASURE -> DIGEST -> IDLE against the hub through
# `mcphost-deploy`, writes one ledger line per run to
# ~/Documents/PRDs/grand-loop/ledger.md, classifies the cycle into one
# failure family (or growing/flat), and replaces today's `## Loop notes`
# line in ~/Documents/PRDs/projects/grand-loop.md so vibeloop's dream reads
# the verdict without a human copying numbers. Never builds, never dreams,
# never spends a model call — see visions/grand-loop.md, "Loop contract".
#
# THIS PASS (first coherent slice of a larger PRD — see PRD Status note):
#   flock (state.lock), STOP (+ MEASURE-OK override), the daily MEASURE cap,
#   PREFLIGHT's db_ok + listings-artifact checks, MEASURE's exit-3
#   (unvalidated) handling, and family classification for instrument /
#   distribution / activation / monetization / retention / discovery /
#   growing / flat. grand-loop-status and the systemd units also ship
#   (iter-2, AC12).
# NOT YET: synthorg-candidates integration, and the P1 daily section /
#   instruction-table env file (AC13).
#
# Env:
#   GRAND_LOOP_PRD_DIR   default $HOME/Documents/PRDs (the PRDs repo clone)
#   GRAND_LOOP_ENV       default $HOME/.config/grand-loop/env, sourced if present
#   GRAND_LOOP_LOG       default $HOME/brain/journal/grand-loop.log
#   GRAND_LOOP_HOST      default "hub" — the --host mcphost-deploy is called with
#   GRAND_LOOP_EXCLUDE_PREFIXES   default "harness-,probe-"
#   GRAND_LOOP_MAX_TICKS_PER_DAY  default 4
set -uo pipefail
# Appended, not overridden: a caller (a test, or a future wrapper) may have
# already put a stand-in `mcphost-deploy` earlier on PATH; under systemd
# (a near-empty PATH) this still guarantees the usual bin dirs are present.
export PATH="$PATH:$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/grand-loop-lib.sh
. "$HERE/../lib/grand-loop-lib.sh"

PRD_DIR="${GRAND_LOOP_PRD_DIR:-$HOME/Documents/PRDs}"
LOOP_DIR="$PRD_DIR/grand-loop"
STATE="$LOOP_DIR/state.json"
LOCK="$LOOP_DIR/state.lock"
LEDGER="$LOOP_DIR/ledger.md"
MEASURE_DIR="$LOOP_DIR/measure"
STOP_FILE="$LOOP_DIR/STOP"
MEASURE_OK_FILE="$LOOP_DIR/MEASURE-OK"
CANDIDATES="$LOOP_DIR/candidates.yaml"
PROFILE="$PRD_DIR/projects/grand-loop.md"
export GRAND_LOOP_LOG="${GRAND_LOOP_LOG:-$HOME/brain/journal/grand-loop.log}"

mkdir -p "$LOOP_DIR" "$MEASURE_DIR" "$(dirname "$GRAND_LOOP_LOG")"

ENV_FILE="${GRAND_LOOP_ENV:-$HOME/.config/grand-loop/env}"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
GRAND_LOOP_EXCLUDE_PREFIXES="${GRAND_LOOP_EXCLUDE_PREFIXES:-harness-,probe-}"
GRAND_LOOP_MAX_TICKS_PER_DAY="${GRAND_LOOP_MAX_TICKS_PER_DAY:-4}"
HOST="${GRAND_LOOP_HOST:-hub}"

# ---- flock: a second start exits 0 within 2s, no ledger line (AC2) --------
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "skip: tick running"
  log "skip: tick running"
  exit 0
fi

today="$(date -u +%F)"

# ---- STOP / MEASURE-OK (AC3) ----------------------------------------------
stop_present=0; [ -f "$STOP_FILE" ] && stop_present=1
measure_ok=0; [ -f "$MEASURE_OK_FILE" ] && measure_ok=1

if [ "$stop_present" = 1 ] && [ "$measure_ok" = 0 ]; then
  bl_phase "$STATE" IDLE "skip: STOP"
  skip_stop_line "$LEDGER"
  echo "skip: STOP"
  log "skip: STOP"
  exit 0
fi
if [ "$measure_ok" = 1 ]; then
  rm -f "$MEASURE_OK_FILE"
  log "MEASURE-OK consumed; forcing measure despite STOP=$stop_present"
fi

# ---- daily MEASURE cap (AC8) — MEASURE-OK forces past it, like STOP -------
if [ "$measure_ok" = 0 ]; then
  measured_today="$(count_reached_measure_today "$LEDGER" "$today")"
  if [ "$measured_today" -ge "$GRAND_LOOP_MAX_TICKS_PER_DAY" ]; then
    bl_phase "$STATE" IDLE "skip: daily cap ($measured_today/$GRAND_LOOP_MAX_TICKS_PER_DAY)"
    echo "skip: daily cap ($measured_today/$GRAND_LOOP_MAX_TICKS_PER_DAY)"
    log "skip: daily cap ($measured_today/$GRAND_LOOP_MAX_TICKS_PER_DAY)"
    exit 0
  fi
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
preflight_json="$tmpdir/preflight.json"
healthz_json="$tmpdir/healthz.json"

# ---- PREFLIGHT --------------------------------------------------------
bl_phase "$STATE" PREFLIGHT running
if ! mcphost-deploy probe --host "$HOST" --json > "$preflight_json" 2>>"$GRAND_LOOP_LOG"; then
  bl_phase "$STATE" DIGEST failed
  finish_instrument "$STATE" "$LEDGER" "$PROFILE" "$PRD_DIR" "" "preflight: probe command failed" 0
  log "instrument: preflight probe command failed"
  exit 0
fi
python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
json.dump(d.get('healthz') or {}, open(sys.argv[2], 'w'))
" "$preflight_json" "$healthz_json" 2>/dev/null || echo '{}' > "$healthz_json"

db_ok="$(python3 -c "import json;print(json.load(open('$healthz_json')).get('db_ok'))" 2>/dev/null || echo False)"
if [ "$db_ok" != "True" ]; then
  bl_phase "$STATE" DIGEST failed
  finish_instrument "$STATE" "$LEDGER" "$PROFILE" "$PRD_DIR" "" "preflight: db_ok failed" 0
  log "instrument: preflight db_ok failed"
  exit 0
fi

# Listings artifact check, when present (AC5): tracks the first-seen-live
# stamp in state.json so DIGEST's classify_family can measure "listings live
# for 14 days" across ticks without a separate history file.
listings_json="$tmpdir/listings.json"
extract_listings_json "$preflight_json" "$listings_json"
update_listings_state "$STATE" "$listings_json"

bl_phase "$STATE" PREFLIGHT ok

# ---- MEASURE ------------------------------------------------------------
bl_phase "$STATE" MEASURE running
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
out_dir="$MEASURE_DIR/$stamp"
mkdir -p "$out_dir"

exclude_args=()
IFS=',' read -ra _pfx <<< "$GRAND_LOOP_EXCLUDE_PREFIXES"
for p in "${_pfx[@]}"; do [ -n "$p" ] && exclude_args+=(--exclude-prefix "$p"); done

measure_out="$tmpdir/measure.out"
measure_rc=0
mcphost-deploy measure --host "$HOST" --out "$out_dir" "${exclude_args[@]}" > "$measure_out" 2>>"$GRAND_LOOP_LOG" || measure_rc=$?

if [ "$measure_rc" -eq 3 ]; then
  detail="$(grep -o 'unvalidated:.*' "$measure_out" | head -1)"
  bl_phase "$STATE" DIGEST failed
  finish_instrument "$STATE" "$LEDGER" "$PROFILE" "$PRD_DIR" "$out_dir" "${detail:-unvalidated}" 1
  log "instrument: measure unvalidated ($detail)"
  exit 0
elif [ "$measure_rc" -ne 0 ]; then
  bl_phase "$STATE" DIGEST failed
  finish_instrument "$STATE" "$LEDGER" "$PROFILE" "$PRD_DIR" "$out_dir" "measure failed rc=$measure_rc" 1
  log "instrument: measure failed rc=$measure_rc"
  exit 0
fi
bl_phase "$STATE" MEASURE ok

# ---- DIGEST ---------------------------------------------------------------
bl_phase "$STATE" DIGEST running
measure_json="$out_dir/measure.json"
if [ ! -f "$measure_json" ]; then
  finish_instrument "$STATE" "$LEDGER" "$PROFILE" "$PRD_DIR" "$out_dir" "measure exited 0 but wrote no measure.json" 1
  log "instrument: measure.json missing"
  exit 0
fi

tenants_jsonl="$out_dir/tenants.jsonl"; [ -f "$tenants_jsonl" ] || tenants_jsonl=""
result="$(classify_family "$measure_json" "$tenants_jsonl" "$CANDIDATES" "$healthz_json" "$LEDGER" "$STATE")"
family="${result%%|*}"
reason="${result#*|}"

write_ledger_line "$LEDGER" "$measure_json" "$family" "$reason" 1
write_loop_note "$PROFILE" "$today" "$family" "$measure_json" "$(family_instruction "$family")"
commit_prd_repo "$PRD_DIR" "$out_dir" "$LEDGER" "$STATE" "$PROFILE"

bl_phase "$STATE" DIGEST ok
bl_phase "$STATE" IDLE ok
echo "family=$family reason=$reason"
log "tick complete family=$family reason=$reason"
