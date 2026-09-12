#!/usr/bin/env bash
# grand-loop-demand.sh — PRD-grand-loop-demand-cadence: the one-read-a-day
# runner for the grand loop's own metric. `mcphost-deploy measure` (the
# command that computes paid_mrr_usd/real_tenants/...) shipped 2026-09-06
# and had never been run unattended — the five-label validation gate
# deadlocks with itself while zero real tenants exist to label. This script
# reads it daily with --allow-unvalidated (every number stamped
# validated:false), appends one ledger row, and turns a failed read or a
# real_tenants movement into a loud event instead of a diff nobody runs.
#
# Subcommands:
#   run       (default) do today's read, unless one already happened today.
#   status    print the last row, days since last success, validated state.
#   install   create every directory the unit writes to, resolve+cache the
#             mcphost-deploy invocation, enable the timer if systemctl is
#             present. Run once by hand after `install.sh` symlinks this
#             repo in (the systemd log-dir gotcha: a missing directory is a
#             silent 209 — this makes every write path exist up front).
#
# Env (all optional):
#   GRAND_LOOP_DEMAND_CLONE_DIR   default $HOME/.cache/grand-loop-demand/prds-clone
#                                  — a DEDICATED clone, never the operator's
#                                  live ~/Documents/PRDs checkout (that one
#                                  gets rebased/autostashed by other tools
#                                  mid-write; a long-running write here would
#                                  vanish under it, same trap vibeloop-measure
#                                  documented for its own evidence writes).
#   GRAND_LOOP_DEMAND_ORIGIN      default https://github.com/j0yen/PRDs.git
#   GRAND_LOOP_DEMAND_BRANCH      default main
#   GRAND_LOOP_DEMAND_HOST        default hub — the --host mcphost-deploy measure gets
#   GRAND_LOOP_DEMAND_LOG         default $HOME/brain/journal/grand-loop-demand.log
#   GRAND_LOOP_DEMAND_MD_CACHE    default $HOME/.config/grand-loop-demand/mcphost-deploy-bin
#   GRAND_LOOP_DEMAND_MD_REPO     default $HOME/repos/mcphost-deploy (uv-run fallback)
#   GRAND_LOOP_DEMAND_TODAY       test-only override for "today" (unset in production)
#   GRAND_LOOP_DEMAND_MD_BIN      test/operator override: exact mcphost-deploy binary to invoke
set -uo pipefail
export PATH="$PATH:$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/grand-loop-demand-lib.sh
. "$HERE/../lib/grand-loop-demand-lib.sh"

CLONE_DIR="${GRAND_LOOP_DEMAND_CLONE_DIR:-$HOME/.cache/grand-loop-demand/prds-clone}"
ORIGIN="${GRAND_LOOP_DEMAND_ORIGIN:-https://github.com/j0yen/PRDs.git}"
BRANCH="${GRAND_LOOP_DEMAND_BRANCH:-main}"
HOST="${GRAND_LOOP_DEMAND_HOST:-hub}"
LOG="${GRAND_LOOP_DEMAND_LOG:-$HOME/brain/journal/grand-loop-demand.log}"
MD_CACHE="${GRAND_LOOP_DEMAND_MD_CACHE:-$HOME/.config/grand-loop-demand/mcphost-deploy-bin}"
MD_REPO="${GRAND_LOOP_DEMAND_MD_REPO:-$HOME/repos/mcphost-deploy}"
LEDGER_REL="grand-loop/demand/ledger.jsonl"
RUNS_REL="grand-loop/demand/runs"
BUS_TOPIC="wm.grandloop.demand"

cmd_install() {
  mkdir -p "$(dirname "$LOG")" "$(dirname "$MD_CACHE")" "$(dirname "$CLONE_DIR")"
  local resolved; resolved="$(resolve_mcphost_deploy "$MD_CACHE" "$MD_REPO")"
  echo "mcphost-deploy resolution: $resolved"
  log_line "$LOG" "install: directories ready, mcphost-deploy resolution: $resolved"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    systemctl --user enable --now grand-loop-demand.timer >/dev/null 2>&1 || true
    log_line "$LOG" "install: grand-loop-demand.timer enabled"
  fi
  echo "install: done"
}

cmd_status() {
  local ledger="$CLONE_DIR/$LEDGER_REL"
  python3 - "$ledger" <<'PY'
import json, sys
from datetime import datetime, timezone
path = sys.argv[1]
try:
    with open(path) as f:
        lines = [l for l in f if l.strip()]
except FileNotFoundError:
    lines = []
if not lines:
    print("last row:    none yet")
    print("days since:  n/a")
    print("validated:   unknown")
    sys.exit(0)
last = json.loads(lines[-1])
if last.get("alarm"):
    print(f"last row:    {last.get('date')} ALARM exit_code={last.get('exit_code')} stderr_tail={last.get('stderr_tail')}")
else:
    print(f"last row:    {last.get('date')} paid_mrr_usd={last.get('paid_mrr_usd')} "
          f"paying_tenants={last.get('paying_tenants')} real_tenants={last.get('real_tenants')} "
          f"real_wow_rate={last.get('real_wow_rate')} gross_churn={last.get('gross_churn')} "
          f"validated={last.get('validated')}")
last_success = None
for line in reversed(lines):
    try:
        r = json.loads(line)
    except Exception:
        continue
    if not r.get("alarm"):
        last_success = r
        break
if last_success:
    try:
        d = datetime.strptime(last_success["date"], "%Y-%m-%d").date()
        days = (datetime.now(timezone.utc).date() - d).days
    except Exception:
        days = "?"
    print(f"days since:  {days} (last success {last_success.get('date')})")
    print(f"validated:   {last_success.get('validated')}")
else:
    print("days since:  n/a (no successful run yet)")
    print("validated:   unknown")
PY
}

cmd_run() {
  local today ts_now
  today="$(demand_today)"
  ts_now="$(now_ts)"

  local clone_state clone_rc
  clone_state="$(ensure_demand_clone "$CLONE_DIR" "$ORIGIN" "$BRANCH")"; clone_rc=$?

  local ledger="$CLONE_DIR/$LEDGER_REL"

  if [ "$clone_rc" -ne 0 ]; then
    log_line "$LOG" "ALARM clone unhealthy state=$clone_state date=$today"
    if [ -d "$CLONE_DIR/.git" ]; then
      mkdir -p "$(dirname "$ledger")"
      local row pstate streak
      row="$(build_alarm_row "$today" "$ts_now" 128 "" "" "$clone_state")"
      append_row "$ledger" "$row"
      pstate="$(commit_and_push "$CLONE_DIR" "$BRANCH" "grand-loop-demand: alarm $today (clone: $clone_state)")"
      if [ "$pstate" = "push-failed" ]; then
        mark_push_failed "$ledger"
        commit_and_push "$CLONE_DIR" "$BRANCH" "grand-loop-demand: mark push-failed $today" >/dev/null 2>&1 || true
      fi
      streak="$(consecutive_alarm_count "$ledger")"
      if [ "$streak" -ge 2 ]; then
        bus_publish "$BUS_TOPIC" "$(printf '{"event":"demand-alarm-streak","count":%s,"date":"%s"}' "$streak" "$today")"
        log_line "$LOG" "bus: demand-alarm-streak count=$streak"
      fi
    fi
    echo "alarm: clone unhealthy ($clone_state)"
    return 0
  fi

  mkdir -p "$(dirname "$ledger")"

  if already_ran_today "$ledger" "$today"; then
    log_line "$LOG" "skip: already ran ($today)"
    echo "skip: already ran"
    return 0
  fi

  local out_dir_rel="$RUNS_REL/$today"
  local out_dir_abs="$CLONE_DIR/$out_dir_rel"
  mkdir -p "$out_dir_abs"

  local resolved mode val
  resolved="$(resolve_mcphost_deploy "$MD_CACHE" "$MD_REPO")"
  mode="${resolved%% *}"; val="${resolved#* }"

  local measure_out="$out_dir_abs/stdout.txt" measure_err="$out_dir_abs/stderr.txt"
  local measure_rc=0
  case "$mode" in
    bin)
      "$val" measure --host "$HOST" --out "$out_dir_abs" --allow-unvalidated >"$measure_out" 2>"$measure_err" || measure_rc=$?
      ;;
    uvrun)
      ( cd "$val" && uv run mcphost-deploy measure --host "$HOST" --out "$out_dir_abs" --allow-unvalidated ) >"$measure_out" 2>"$measure_err" || measure_rc=$?
      ;;
    *)
      echo "mcphost-deploy not resolvable (checked PATH and $val)" > "$measure_err"
      measure_rc=127
      ;;
  esac

  local measure_json="$out_dir_abs/measure.json"
  local row is_alarm=0
  if [ "$measure_rc" -eq 0 ] && [ -f "$measure_json" ]; then
    local prev; prev="$(last_success_row_field "$ledger" real_tenants)"
    [ -z "$prev" ] && prev=0
    row="$(build_success_row "$measure_json" "$today" "$ts_now" "$measure_rc" "$out_dir_rel" "$clone_state" "$prev")"
  else
    is_alarm=1
    row="$(build_alarm_row "$today" "$ts_now" "$measure_rc" "$out_dir_rel/stderr.txt" "$out_dir_rel" "$clone_state")"
  fi

  append_row "$ledger" "$row"

  local commit_msg
  if [ "$is_alarm" -eq 1 ]; then
    commit_msg="grand-loop-demand: $today alarm exit=$measure_rc"
    log_line "$LOG" "ALARM demand read failed exit=$measure_rc date=$today out_dir=$out_dir_rel"
  else
    commit_msg="grand-loop-demand: $today row"
    log_line "$LOG" "ok: demand row appended date=$today out_dir=$out_dir_rel"
  fi

  local pstate; pstate="$(commit_and_push "$CLONE_DIR" "$BRANCH" "$commit_msg")"
  if [ "$pstate" = "push-failed" ]; then
    mark_push_failed "$ledger"
    commit_and_push "$CLONE_DIR" "$BRANCH" "grand-loop-demand: mark push-failed $today" >/dev/null 2>&1 || true
    log_line "$LOG" "warn: push failed for $today row (will retry next successful run)"
  fi

  if [ "$is_alarm" -eq 1 ]; then
    local streak; streak="$(consecutive_alarm_count "$ledger")"
    if [ "$streak" -ge 2 ]; then
      bus_publish "$BUS_TOPIC" "$(printf '{"event":"demand-alarm-streak","count":%s,"date":"%s"}' "$streak" "$today")"
      log_line "$LOG" "bus: demand-alarm-streak count=$streak"
    fi
  else
    local changed; changed="$(python3 -c "import json,sys;print(json.loads(sys.argv[1]).get('real_tenants_changed'))" "$row" 2>/dev/null)"
    if [ "$changed" = "True" ]; then
      local rt rtp
      rt="$(python3 -c "import json,sys;print(json.loads(sys.argv[1]).get('real_tenants'))" "$row")"
      rtp="$(python3 -c "import json,sys;print(json.loads(sys.argv[1]).get('real_tenants_prev'))" "$row")"
      bus_publish "$BUS_TOPIC" "$(printf '{"event":"real-tenants-moved","from":%s,"to":%s,"date":"%s"}' "$rtp" "$rt" "$today")"
      log_line "$LOG" "bus: real-tenants-moved $rtp -> $rt"
    fi
  fi

  echo "ok: demand row appended for $today"
}

cmd="${1:-run}"
case "$cmd" in
  run) cmd_run ;;
  status) cmd_status ;;
  install) cmd_install ;;
  *) echo "usage: grand-loop-demand.sh [run|status|install]" >&2; exit 2 ;;
esac
