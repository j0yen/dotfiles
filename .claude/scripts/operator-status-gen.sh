#!/usr/bin/env bash
# operator-status-gen.sh [--out <path>] — write the operator status.json
# (PRD dotfiles-operator-status-card R1/R2). Read-only against wm-build's
# state.db, journal tail, synthorg chain files, `agorabus intent list` and
# the wm-build systemd unit. Every source is fail-open: a missing/slow one
# sets sources.<key> and leaves its field null. Always exits 0.
#
# Test/override env: OPERATOR_CACHE_DIR, WM_BUILD_STATE_DIR, OPERATOR_WM_BIN,
# WM_BUILD_CONFIG, SYNTHORG_STATE_DIR, OPERATOR_CHAIN_HOST,
# OPERATOR_PROC_ROOT, OPERATOR_WM_UNIT, CLAUDE_AGORABUS_SID.
set -uo pipefail

cache="${OPERATOR_CACHE_DIR:-$HOME/.cache/operator}"
out="$cache/status.json"
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out="${2:-$out}"; shift 2 ;;
    *) shift ;;
  esac
done

state="${WM_BUILD_STATE_DIR:-$HOME/.local/state/wm-build}"
db="$state/state.db"
journal="$state/journal.jsonl"
wm_bin="${OPERATOR_WM_BIN:-$HOME/.cargo/bin/wm-build}"
wm_cfg="${WM_BUILD_CONFIG:-$HOME/.config/wm-build/config.toml}"
syn="${SYNTHORG_STATE_DIR:-$HOME/.local/state/synthorg}"
chain_host="${OPERATOR_CHAIN_HOST:-orch}"
procroot="${OPERATOR_PROC_ROOT:-/proc}"
unit="${OPERATOR_WM_UNIT:-wm-build.service}"

declare -A SRC
q() { # q <sql> — JSON array of rows from state.db, '[]' when none; rc!=0 on failure
  local o rc
  o=$(timeout 1 sqlite3 -readonly -json "$db" "$1" 2>/dev/null); rc=$?
  [ $rc -ne 0 ] && return $rc
  printf '%s' "${o:-[]}"
}
src_rc() { # src_rc <key> <rc> — record ok/timeout/missing from an exit code
  case "$2" in 0) SRC[$1]=ok ;; 124) SRC[$1]=timeout ;; *) SRC[$1]=missing ;; esac
}
iso_epoch() { date -d "$1" +%s 2>/dev/null; }

null=null; runs=null; decisions=null; cfgwall=null
tick=""; db_ok=0
[ -r "$db" ] && db_ok=1

# runs — open rows
if [ $db_ok -eq 1 ]; then
  r=$(q "select id, slug, stage, cast((julianday('now')-julianday(started))*1440 as int) as age_min, created_by, mode from runs where ended is null order by id")
  rc=$?; src_rc runs $rc; [ $rc -eq 0 ] && runs="$r"
  d=$(q "select d.id as id, coalesce(r.slug, d.ref_) as slug, d.cause as cause, d.opened as opened from decisions d left join runs r on cast(r.id as text)=d.run_id where d.closed is null and d.closed_at is null order by d.id")
  rc=$?; src_rc decisions $rc; [ $rc -eq 0 ] && decisions="$d"
else
  SRC[runs]=missing; SRC[decisions]=missing
fi

# queue — newest daemon/tick row from the journal tail (progressive, never a full scan)
queue=null
if [ -r "$journal" ]; then
  line=""
  for n in 262144 1048576; do
    line=$(timeout 1 tail -c "$n" "$journal" 2>/dev/null | grep -aE '"op": ?"tick"' | tail -n 1)
    [ -n "$line" ] && break
  done
  if [ -n "$line" ] && jq -e . >/dev/null 2>&1 <<<"$line"; then
    tick="$line"
    queue=$(jq -c '(.row // .) | {admitted: (.admitted // []), skipped: ((.skipped // []) | group_by(.reason) | map({reason: .[0].reason, slugs: map(.slug)})), slots: (.slots // null), boxes: (.boxes // null)}' <<<"$tick")
    SRC[queue]=ok
  else
    SRC[queue]=missing
  fi
else
  SRC[queue]=missing
fi

# chain — newest chain-ledger row (+ chain-progress when present)
chain=$(jq -nc --arg h "$chain_host" '{host:$h}')
if [ -r "$syn/runs/chain-ledger.jsonl" ]; then
  c=$(timeout 1 tail -n 1 "$syn/runs/chain-ledger.jsonl" 2>/dev/null | jq -c '{host: null, chain_run_id, link, status, ts}' 2>/dev/null)
  if [ -n "$c" ]; then
    prog=null
    [ -r "$syn/runs/chain-progress.jsonl" ] && prog=$(timeout 1 tail -n 1 "$syn/runs/chain-progress.jsonl" 2>/dev/null | jq -c . 2>/dev/null || echo null)
    chain=$(jq -c --argjson p "${prog:-null}" --arg h "$chain_host" '.host=$h | if $p == null then . else .progress=$p end' <<<"$c")
    SRC[chain]=ok
  else SRC[chain]=missing; fi
else
  SRC[chain]=missing
fi

# siblings — agorabus intent list minus self
siblings=null
if command -v agorabus >/dev/null 2>&1; then
  self="${CLAUDE_AGORABUS_SID:-}"
  if [ -z "$self" ] && [ -r "$HOME/.claude/scripts/agorabus-sid.sh" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.claude/scripts/agorabus-sid.sh"
    self=$(agorabus_derive_sid "$(agorabus_derive_root_pid "$PPID")" "$(basename "$PWD")" 2>/dev/null)
  fi
  s=$(timeout 1 agorabus intent list 2>/dev/null); rc=$?
  src_rc siblings $rc
  if [ $rc -eq 0 ]; then
    siblings=$(jq -c --arg self "$self" '[.[] | select(.session_id != $self) | {session_id, skill: (.skill // null), prd: (.prd // null), since: (.since // .started_at // .ts // null)}]' <<<"${s:-[]}" 2>/dev/null) || { siblings=null; SRC[siblings]=missing; }
  fi
else
  SRC[siblings]=missing
fi

# daemon — meta.daemon_started_at, unit start, running exe version, binary on disk
daemon=null
started=""
[ $db_ok -eq 1 ] && started=$(timeout 1 sqlite3 -readonly "$db" "select value from meta where key='daemon_started_at'" 2>/dev/null)
sd=$(timeout 1 systemctl --user show -p ExecMainPID -p ExecMainStartTimestamp "$unit" 2>/dev/null)
pid=$(sed -n 's/^ExecMainPID=//p' <<<"$sd"); exec_start=$(sed -n 's/^ExecMainStartTimestamp=//p' <<<"$sd")
runver=""
if [ -n "$pid" ] && [ "$pid" != 0 ] && [ -x "$procroot/$pid/exe" ]; then
  runver=$(timeout 1 "$procroot/$pid/exe" --version 2>/dev/null | awk '{print $NF}')
fi
binver=""; bmtime=""; bepoch=""
if [ -x "$wm_bin" ]; then
  binver=$(timeout 1 "$wm_bin" --version 2>/dev/null | awk '{print $NF}')
  bepoch=$(stat -c %Y "$wm_bin" 2>/dev/null)
  [ -n "$bepoch" ] && bmtime=$(date -u -d "@$bepoch" +%Y-%m-%dT%H:%M:%SZ)
fi
swapped=null
if [ -n "$started" ] && [ -n "$bepoch" ]; then
  se=$(iso_epoch "$started")
  [ -n "$se" ] && { [ "$bepoch" -gt "$se" ] && swapped=true || swapped=false; }
fi
if [ -n "$started" ] && [ -n "$bepoch" ]; then
  daemon=$(jq -nc --arg st "$started" --arg es "$exec_start" --arg pid "$pid" --arg rv "$runver" --arg bp "$wm_bin" --arg bm "$bmtime" --arg bv "$binver" --argjson sw "$swapped" \
    '{started_at:$st, exec_start:(if $es=="" then null else $es end), pid:(if $pid=="" then null else ($pid|tonumber? // null) end), running_version:(if $rv=="" then null else $rv end), binary:{path:$bp, mtime:$bm, version:(if $bv=="" then null else $bv end)}, swapped_after_start:$sw}')
  SRC[daemon]=ok
else
  SRC[daemon]=missing
fi

# config — file mtime, newest effective_config load, last tick load, restart-required rows
config=null
if [ $db_ok -eq 1 ]; then
  loaded=$(timeout 1 sqlite3 -readonly "$db" "select max(loaded_at) from effective_config" 2>/dev/null)
  cmt=""; [ -e "$wm_cfg" ] && cmt=$(date -u -d "@$(stat -c %Y "$wm_cfg")" +%Y-%m-%dT%H:%M:%SZ)
  tickload=""; [ -n "$tick" ] && tickload=$(jq -r '(.row // .).config_loaded_at // empty' <<<"$tick")
  rr=0
  if [ -r "$journal" ] && [ -n "$started" ]; then
    rr=$(timeout 1 tail -c 1048576 "$journal" 2>/dev/null | grep -a 'config-restart-required' | grep -c .) || rr=0
  fi
  walls=$(q "select key, value from effective_config where key like '%wall_minutes'" || echo '[]')
  cfgwall=$(jq -c 'map({(.key|sub("\\.?wall_minutes$";"")|sub("^.*\\.";"")): (.value|tonumber? // null)}) | add // {}' <<<"${walls:-[]}" 2>/dev/null || echo '{}')
  if [ -n "$loaded" ]; then
    config=$(jq -nc --arg m "$cmt" --arg l "$loaded" --arg t "$tickload" --argjson rr "$rr" --argjson w "$cfgwall" \
      '{file_mtime:(if $m=="" then null else $m end), effective_loaded_at:$l, tick_loaded_at:(if $t=="" then null else $t end), restart_required:$rr, wall_minutes:$w}')
    SRC[config]=ok
  else SRC[config]=missing; fi
else
  SRC[config]=missing
fi

sources=$(for k in runs queue decisions chain siblings daemon config; do printf '%s\t%s\n' "$k" "${SRC[$k]:-missing}"; done | jq -Rn '[inputs|split("\t")|{(.[0]):.[1]}]|add')

mkdir -p "$(dirname "$out")" 2>/dev/null
tmp="$out.tmp.$$"
jq -n --arg ga "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg host "$(hostname -s 2>/dev/null)" \
  --argjson runs "$runs" --argjson queue "$queue" --argjson dec "$decisions" --argjson chain "$chain" \
  --argjson sib "$siblings" --argjson daemon "$daemon" --argjson config "$config" --argjson src "$sources" \
  '{generated_at:$ga, host:$host, runs:$runs, queue:$queue, decisions_open:$dec, chain:$chain, siblings:$sib, daemon:$daemon, config:$config, sources:$src}' >"$tmp" 2>/dev/null \
  && mv -f "$tmp" "$out"
rm -f "$tmp" 2>/dev/null

# PRD dotfiles-handoff-generated R5: a fresh status.json also refreshes the
# generated handoff when that file is > 20 min old. Only where the memory dir
# exists, never from inside handoff-gen.sh's own call (HANDOFF_GEN_ACTIVE).
hmem="${HANDOFF_MEMORY_DIR:-$HOME/.claude/projects/-home-jsy/memory}"
hgen="$(dirname "${BASH_SOURCE[0]}")/handoff-gen.sh"
if [ -z "${HANDOFF_GEN_ACTIVE:-}" ] && [ -d "$hmem" ] && [ -x "$hgen" ] \
   && [ -z "$(find "$hmem/handoff-generated-$(hostname -s 2>/dev/null).md" -mmin -20 2>/dev/null)" ]; then
  ( setsid "$hgen" >/dev/null 2>&1 & ) 2>/dev/null
fi
exit 0
