#!/usr/bin/env bash
# mcphost-explore-run.sh — PRD-mcphost-explore-first-light: the weekly
# revealed-preference exploration run. Stands up a fresh local mcphost at
# the newest tagged release, drives synthorg's explore -> usecases ->
# export-evidence pipeline against it under Joe's pinned budget (24
# sessions/week, pinned panel composition, rank weights equal), exports the
# mined pack to evidence/mcp-host/exploration/<ts>/ in the PRDs workspace,
# scores the novelty gate, and tears the instance down completely on every
# exit path — success, refusal, or mid-stage failure alike.
#
# Fired weekly (Sunday 03:00Z) by mcphost-explore-run.timer via
# mcphost-explore-run.service. Also runs `status` (P1) and `--dry-run` (P2)
# on demand.
#
# Every path below that touches something real is overridable by an env
# var so tests/explorefirst_ac*.test.sh can run this script unmodified
# against fakes with no network, no cargo, no real synthorg/mcphost, and no
# git push:
#   EXPLOREFIRST_PRD_DIR       PRDs workspace root (default ~/repos/PRDs)
#   EXPLOREFIRST_LOG           journal log path
#   EXPLOREFIRST_SYN           synthorg checkout (default ~/repos/synthorg)
#   EXPLOREFIRST_CRATE         mcphost checkout for tag resolution (default ~/wintermute/mcphost)
#   EXPLOREFIRST_MCPHOST_BIN   skip tag resolution/build entirely; use this binary
#   EXPLOREFIRST_SYNTHORG_BIN  skip `uv run synthorg`; exec this instead (fakes: dispatcher script)
#   EXPLOREFIRST_SEGMENTS      skip reading panel-composition.yaml; use this comma list
#   EXPLOREFIRST_COMPOSITION   path to panel-composition.yaml (default corpora/mcphost/panel-composition.yaml under SYN)
#   EXPLOREFIRST_SESSIONS      pinned session count (default 24, Joe 2026-09-10)
#   EXPLOREFIRST_BUDGET_ASSERT synthorg `obs --assert` clause (placeholder pending Joe's exact ceiling — see below)
#   EXPLOREFIRST_VIBELOOP_UNIT the systemd unit checked for mid-cycle (default claude-vibeloop-work.service)
#   EXPLOREFIRST_WORK          scratch root for in-progress runs/packs (default a mktemp dir)
#   EXPLOREFIRST_NOW           pin "now" (ISO-8601 UTC) for iso_week() in tests
#   EXPLOREFIRST_HEALTH_TRIES / EXPLOREFIRST_HEALTH_INTERVAL  health-wait polling
#   EXPLOREFIRST_NO_PUSH=1     land the pack/ledger/dream-log commit but skip `git push` (tests)
#
# NOTE on EXPLOREFIRST_BUDGET_ASSERT: Joe's 2026-09-10 resolution pins
# session/run counts (24 sessions, one run/week) but visions/mcp-host.md
# line 1125 leaves the exact call/token ceiling clause to "at build of
# explore-sessions" — that build didn't fix a number either (grep of
# PRD-synthorg-explore-sessions.md: none). The default below is a
# conservative placeholder sized off a 24-session run at the harness's
# default per-session turn budget; Joe can override it in
# ~/.config/mcphost-explore/budget-assert without a script change, and a
# too-tight or too-loose default here is exactly the "pipeline defect
# found by the first run" this PRD's Non-goals send to its own PRD, not a
# reason to block shipping the runner.
set -uo pipefail
# EXPLOREFIRST_EXTRA_PATH (tests only): a fake-binary dir prepended ahead of
# everything else, so tests/explorefirst_ac*.test.sh's fake mcphost/synthorg/
# curl/systemctl win over the real ones without this script trusting
# whatever PATH the caller happened to have (same reasoning as the fixed
# PATH below, which is why it can't just inherit a test's PATH directly).
export PATH="${EXPLOREFIRST_EXTRA_PATH:+$EXPLOREFIRST_EXTRA_PATH:}$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/mcphost-explore-lifecycle.sh
. "$HERE/../lib/mcphost-explore-lifecycle.sh"

PRD_DIR="${EXPLOREFIRST_PRD_DIR:-$HOME/repos/PRDs}"
LOG="${EXPLOREFIRST_LOG:-$HOME/brain/journal/mcphost-explore-run.log}"
SYN="${EXPLOREFIRST_SYN:-$HOME/repos/synthorg}"
CRATE="${EXPLOREFIRST_CRATE:-$HOME/wintermute/mcphost}"
EVD="$PRD_DIR/evidence/mcp-host/exploration"
WEEKS_DIR="$EVD/.weeks"
LEDGER="$PRD_DIR/vibeloop/exploration-ledger.md"
DREAM_LOG="$PRD_DIR/notes/dream-log.md"
COMPOSITION="${EXPLOREFIRST_COMPOSITION:-$SYN/corpora/mcphost/panel-composition.yaml}"
SESSIONS="${EXPLOREFIRST_SESSIONS:-24}"
if [ -n "${EXPLOREFIRST_BUDGET_ASSERT:-}" ]; then
  BUDGET_ASSERT="$EXPLOREFIRST_BUDGET_ASSERT"
elif [ -f "$HOME/.config/mcphost-explore/budget-assert" ]; then
  BUDGET_ASSERT="$(tr -d '\n' < "$HOME/.config/mcphost-explore/budget-assert")"
else
  BUDGET_ASSERT="calls<=3000,tokens_out<=600000"
fi
SYSTEMCTL_UNIT="${EXPLOREFIRST_VIBELOOP_UNIT:-claude-vibeloop-work.service}"
WORK="${EXPLOREFIRST_WORK:-}"
[ -n "$WORK" ] || WORK="$(mktemp -d "${TMPDIR:-/tmp}/mcphost-explore-work.XXXXXX")"

mkdir -p "$(dirname "$LOG")" "$EVD" "$WEEKS_DIR" "$(dirname "$LEDGER")" "$(dirname "$DREAM_LOG")"

ts() { # honors EXPLOREFIRST_NOW (tests: makes ledger/dream-log lines byte-reproducible
       # across repeated invocations pinned to the same "now" — AC6's "second
       # identical export attempt" needs a real byte-identical dream-log append
       # to prove the commit step itself is a no-op, not just a skipped run)
  if [ -n "${EXPLOREFIRST_NOW:-}" ]; then
    date -u -d "$EXPLOREFIRST_NOW" +%Y-%m-%dT%H:%M:%SZ
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}
log() { echo "$(ts) $*" >> "$LOG"; }
bus() { # best-effort local coordination event; never fails the run
  command -v agorabus >/dev/null 2>&1 && \
    timeout 5 agorabus publish mcphost.explore.consecutive-failures "$1" --session-id mcphost-explore-run >/dev/null 2>&1
  return 0
}

# -- helpers -----------------------------------------------------------------

pick_ephemeral_port() {
  python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}

resolve_mcphost_bin() {
  if [ -n "${EXPLOREFIRST_MCPHOST_BIN:-}" ]; then
    printf '%s\n' "$EXPLOREFIRST_MCPHOST_BIN"
    return 0
  fi
  local tag built cached
  tag="$(git -C "$CRATE" tag -l 'v*' --sort=-v:refname 2>/dev/null | head -1)"
  if [ -z "$tag" ]; then
    log "resolve_mcphost_bin: no v* tag found in $CRATE"
    return 1
  fi
  built="${tag#v}"
  # shellcheck source=../lib/vibeloop-target-root.sh
  . "$HERE/../lib/vibeloop-target-root.sh"
  cached="$(cargo_target_root)/vibeloop-build-$built/release/mcphost"
  if [ -x "$cached" ]; then
    log "resolve_mcphost_bin: reusing cached release build for $tag ($cached)"
    printf '%s\n' "$cached"
    return 0
  fi
  log "resolve_mcphost_bin: no cached build for $tag; building a bounded local release (cargo-budget guard applies)"
  build_tag_worktree "$CRATE" "$built" "$tag" "$LOG"
}

run_synthorg() {
  if [ -n "${EXPLOREFIRST_SYNTHORG_BIN:-}" ]; then
    "$EXPLOREFIRST_SYNTHORG_BIN" "$@"
  else
    ( cd "$SYN" && uv run synthorg "$@" )
  fi
}

composition_segments() {
  if [ -n "${EXPLOREFIRST_SEGMENTS:-}" ]; then
    printf '%s\n' "$EXPLOREFIRST_SEGMENTS"
    return 0
  fi
  python3 - "$COMPOSITION" <<'PY'
import sys
import yaml
with open(sys.argv[1]) as f:
    d = yaml.safe_load(f) or {}
print(",".join(sorted((d.get("segments") or {}).keys())))
PY
}

wait_health() { # $1=url
  local url="$1" hc i
  hc="${url%/mcp}/healthz"
  for i in $(seq 1 "${EXPLOREFIRST_HEALTH_TRIES:-30}"); do
    if curl -s --max-time 2 "$hc" 2>/dev/null | grep -q '"ok"[[:space:]]*:[[:space:]]*true'; then
      return 0
    fi
    sleep "${EXPLOREFIRST_HEALTH_INTERVAL:-1}"
  done
  return 1
}

# usecases.json -> "candidates_total novel_count" ("0 0" on any read failure)
usecases_gate_fields() { # $1=run_dir
  python3 - "$1/usecases.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(len(d.get("candidates") or []), d.get("novel_count", 0))
except Exception:
    print("0 0")
PY
}

# Merge P1 cost/session fields from <run_dir>/telemetry.json into the pack's
# manifest.json (requirement 7). Never fails the run — an unreadable
# telemetry.json or missing manifest.json just leaves the fields "unknown".
merge_manifest_cost_fields() { # $1=run_dir $2=pack_dir
  local run_dir="$1" manifest="$2/manifest.json"
  [ -f "$manifest" ] || return 0
  python3 - "$run_dir/telemetry.json" "$manifest" <<'PY'
import json, sys
tel_path, manifest_path = sys.argv[1], sys.argv[2]
sessions = "unknown"
cost = "unknown"
try:
    tel = json.load(open(tel_path))
    sessions = (tel.get("weeks_or_stages") or {}).get("sessions", "unknown")
    cost = tel.get("est_cost_usd", "unknown")
except Exception:
    pass
try:
    with open(manifest_path) as f:
        m = json.load(f)
except Exception:
    m = {}
m["sessions_completed"] = sessions
m["est_cost_usd"] = cost
with open(manifest_path, "w") as f:
    json.dump(m, f, indent=2)
    f.write("\n")
PY
}

record_fail() { # $1=stage $2=msg -> appends ledger fail line, fires the two-consecutive check
  local stage="$1" msg="$2" week
  week="$(iso_week)"
  log "FAIL stage=$stage: $msg"
  printf '%s week=%s status=fail stage=%s msg=%q\n' "$(ts)" "$week" "$stage" "$msg" >> "$LEDGER"
  local weeks
  if weeks="$(two_consecutive_failures "$LEDGER")"; then
    log "two consecutive weekly failures ($weeks) — publishing agorabus event"
    bus "{\"event\":\"mcphost-explore-consecutive-failures\",\"weeks\":\"$weeks\",\"ts\":\"$(ts)\"}"
  fi
}

# -- status (P1 requirement 8) ------------------------------------------------

cmd_status() {
  if [ ! -f "$LEDGER" ]; then
    echo "no runs recorded yet"
    return 0
  fi
  local last_ok
  last_ok="$(grep 'status=ok' "$LEDGER" | tail -1)"
  local next_fire
  next_fire="$(systemctl --user list-timers mcphost-explore-run.timer --no-legend 2>/dev/null | awk '{print $1, $2, $3}')"
  [ -n "$next_fire" ] || next_fire="unknown"
  if [ -z "$last_ok" ]; then
    echo "last_run=none status=$(tail -1 "$LEDGER" | grep -oE 'status=[^ ]+' | cut -d= -f2) next_fire=$next_fire"
    return 0
  fi
  local run_ts week pack candidates novel gate
  run_ts="$(printf '%s\n' "$last_ok" | awk '{print $1}')"
  week="$(printf '%s\n' "$last_ok" | grep -oE 'week=[^ ]+' | cut -d= -f2)"
  pack="$(printf '%s\n' "$last_ok" | grep -oE 'pack=[^ ]+' | cut -d= -f2)"
  candidates="$(printf '%s\n' "$last_ok" | grep -oE 'candidates=[^ ]+' | cut -d= -f2)"
  novel="$(printf '%s\n' "$last_ok" | grep -oE 'novel=[^ ]+' | cut -d= -f2)"
  gate="$(printf '%s\n' "$last_ok" | grep -oE 'gate_met=[^ ]+' | cut -d= -f2)"
  echo "last_run=$run_ts week=$week pack=$pack novelty=${novel:-0}/${candidates:-0} gate_met=${gate:-no} next_fire=$next_fire"
  return 0
}

# -- main ---------------------------------------------------------------------

main() {
  local dry_run=0
  case "${1:-}" in
    status) cmd_status; exit $? ;;
    --dry-run) dry_run=1 ;;
    "") ;;
    *) echo "usage: $(basename "$0") [--dry-run|status]" >&2; exit 2 ;;
  esac

  local week; week="$(iso_week)"
  local week_marker="$WEEKS_DIR/$week"
  if [ "$dry_run" -eq 0 ] && [ -f "$week_marker" ]; then
    log "skip: this week ran ($week, pack: $(cat "$week_marker" 2>/dev/null))"
    echo "skip: this week ran"
    exit 0
  fi

  if vibeloop_mid_cycle "$SYSTEMCTL_UNIT"; then
    log "skip: vibeloop measure mid-cycle ($SYSTEMCTL_UNIT active) — deferring, no instance started"
    echo "skip: vibeloop mid-cycle"
    exit 0
  fi

  local data_dir port admin_key url bin pid stage
  stage="build"
  data_dir="$(mktemp -d "${TMPDIR:-/tmp}/mcphost-explore-data.XXXXXX")"
  port="$(pick_ephemeral_port)"
  admin_key="$(head -c32 /dev/urandom 2>/dev/null | base64 | tr -dc 'A-Za-z0-9' | head -c32)"
  [ -n "$admin_key" ] || admin_key="explorefirst-$$-$(date +%s)"
  url="http://127.0.0.1:$port/mcp"
  pid=""

  cleanup() {
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null
      local waited=0
      while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 10 ]; do sleep 0.2; waited=$((waited+1)); done
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    fi
    rm -rf "$data_dir"
    if pgrep -f "mcphost.*$data_dir" >/dev/null 2>&1; then
      log "WARNING: a process still matches the torn-down data dir $data_dir"
    fi
  }
  trap cleanup EXIT

  bin="$(resolve_mcphost_bin)"
  if [ -z "$bin" ] || [ ! -x "$bin" ]; then
    record_fail build "could not resolve/build an mcphost binary"
    exit 1
  fi

  stage="start"
  if ! MCPHOST_DATA_DIR="$data_dir" "$bin" migrate >>"$LOG" 2>&1; then
    record_fail start "mcphost migrate failed against ephemeral data dir"
    exit 1
  fi
  MCPHOST_DATA_DIR="$data_dir" MCPHOST_BIND="127.0.0.1:$port" \
    MCPHOST_ADMIN_KEY="$admin_key" MCPHOST_PUBLIC_URL="http://127.0.0.1:$port" \
    "$bin" serve >>"$LOG" 2>&1 &
  pid=$!
  if ! wait_health "$url"; then
    record_fail start "health check timed out waiting for $url"
    exit 1
  fi
  log "instance healthy: $url (pid $pid, data_dir $data_dir)"

  if [ "$dry_run" -eq 1 ]; then
    log "dry-run: instance up and healthy, zero sessions run, tearing down, no pack written"
    echo "dry-run ok"
    exit 0
  fi

  local run_dir="$WORK/explore-run"
  mkdir -p "$WORK"
  segments="$(composition_segments)"
  if [ -z "$segments" ]; then
    record_fail explore "no segments resolved from panel composition"
    exit 1
  fi

  stage="explore"
  local explore_out
  if ! explore_out="$(run_synthorg explore "$run_dir" --segments "$segments" --sessions "$SESSIONS" --host "$url" --composition "$COMPOSITION" 2>&1)"; then
    log "explore stage output: $explore_out"
    record_fail explore "explore entrypoint failed"
    exit 1
  fi
  log "explore stage ok: $explore_out"

  local budget_out
  if ! budget_out="$(run_synthorg obs "$run_dir" --assert "$BUDGET_ASSERT" 2>&1)"; then
    log "budget assert output: $budget_out"
    record_fail explore "budget assert exceeded ($BUDGET_ASSERT)"
    exit 1
  fi
  log "budget assert ok: $budget_out"

  stage="mine"
  local mine_out
  if ! mine_out="$(run_synthorg usecases "$run_dir" --out "$run_dir" 2>&1)"; then
    log "mine stage output: $mine_out"
    record_fail mine "usecase mining failed"
    exit 1
  fi
  log "mine stage ok: $mine_out"

  stage="export"
  local pack_work="$WORK/pack"
  rm -rf "$pack_work"
  local export_out
  if ! export_out="$(run_synthorg export-evidence "$run_dir" --kind exploration --out "$pack_work" 2>&1)"; then
    log "export stage output: $export_out"
    record_fail export "export-evidence failed"
    exit 1
  fi
  log "export stage ok: $export_out"

  read -r candidates novel <<< "$(usecases_gate_fields "$run_dir")"
  local gate_met=no
  novelty_gate_met "$novel" && gate_met=yes
  echo "candidates=$candidates novel=$novel gate_met=$gate_met" > "$pack_work/novelty-result.txt"
  merge_manifest_cost_fields "$run_dir" "$pack_work"

  stage="commit"
  local ts_dir final_pack
  if [ -n "${EXPLOREFIRST_NOW:-}" ]; then
    ts_dir="$(date -u -d "$EXPLOREFIRST_NOW" +%Y%m%dT%H%M%SZ)"
  else
    ts_dir="$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  final_pack="$EVD/$ts_dir"
  mkdir -p "$(dirname "$final_pack")"
  rm -rf "$final_pack"
  mv "$pack_work" "$final_pack"
  mkdir -p "$WEEKS_DIR"
  printf '%s\n' "$final_pack" > "$week_marker"

  # AC6: idempotent by pack path — a second attempt that lands the exact
  # same final_pack (same pinned "now"/ts_dir, e.g. a retried commit after
  # this step half-completed) must not double the dream-log note; the git
  # add/diff --cached --quiet below already makes the pack dir itself a
  # no-op when its content is unchanged, but an unconditional append here
  # would still manufacture a real diff on the note alone.
  if ! grep -qF "Pack: $final_pack" "$DREAM_LOG" 2>/dev/null; then
    {
      echo ""
      echo "## $(ts)  mcphost-explore-run  week $week"
      echo "Pack: $final_pack — candidates=$candidates novel=$novel gate_met=$gate_met"
    } >> "$DREAM_LOG"
  fi

  ( cd "$PRD_DIR" && git pull --rebase --autostash -q ) >>"$LOG" 2>&1 || true
  git -C "$PRD_DIR" add "$final_pack" "$DREAM_LOG" "$week_marker"
  if git -C "$PRD_DIR" diff --cached --quiet; then
    log "export commit: nothing staged (AC6 no-op — pack already committed)"
  else
    if git -C "$PRD_DIR" commit -q -m "mcphost-explore: pack $ts_dir (novel=$novel/$candidates gate_met=$gate_met)"; then
      if [ "${EXPLOREFIRST_NO_PUSH:-0}" != "1" ]; then
        git -C "$PRD_DIR" push -q >>"$LOG" 2>&1 || log "WARNING: push failed for pack $ts_dir (commit landed locally)"
      fi
    else
      log "WARNING: commit failed for pack $ts_dir"
    fi
  fi

  printf '%s week=%s status=ok pack=%s candidates=%s novel=%s gate_met=%s\n' \
    "$(ts)" "$week" "$final_pack" "$candidates" "$novel" "$gate_met" >> "$LEDGER"

  log "run complete: pack=$final_pack novel=$novel/$candidates gate_met=$gate_met"
  echo "$final_pack"
  exit 0
}

main "$@"
