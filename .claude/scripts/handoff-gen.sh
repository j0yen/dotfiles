#!/usr/bin/env bash
# handoff-gen.sh [--out <path>] — write the generated handoff
# (PRD dotfiles-handoff-generated R1-R3). Eight sections, every header carries
# its source; every section is fail-open (`<Section>: not on this host`);
# idempotent (only the `Generated:` line varies); atomic (tmp + mv). Always
# exits 0, wall < 3 s. Upstream is ~/.cache/operator/status.json (the status
# card); this script adds only runs ended in 24 h, mcphost prod and synthorg tag.
#
# R5/AC7: a status.json older than 60 s is regenerated first (operator-status-gen.sh).
#
# Test/override env: HANDOFF_STATUS_GEN, HANDOFF_MEMORY_DIR, OPERATOR_CACHE_DIR, WM_BUILD_STATE_DIR,
# HANDOFF_MCPHOST_URL, HANDOFF_SYNTHORG_REPO.
set -uo pipefail

memdir="${HANDOFF_MEMORY_DIR:-$HOME/.claude/projects/-home-jsy/memory}"
cache="${OPERATOR_CACHE_DIR:-$HOME/.cache/operator}"
status="$cache/status.json"
state="${WM_BUILD_STATE_DIR:-$HOME/.local/state/wm-build}"
db="$state/state.db"
mc_url="${HANDOFF_MCPHOST_URL:-https://mcphost.dev/status.json}"
syn_repo="${HANDOFF_SYNTHORG_REPO:-$HOME/repos/synthorg}"
out="$memdir/handoff-generated.md"
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out="${2:-$out}"; shift 2 ;;
    *) shift ;;
  esac
done

# mcphost prod runs in the background so its 2 s timeout overlaps the other reads
mc_tmp=$(mktemp 2>/dev/null) || mc_tmp=/dev/null
( curl -s -m 2 -o "$mc_tmp" "$mc_url" 2>/dev/null ) &
mc_pid=$!

NOHOST="not on this host"
sj() { jq -r "$1" "$status" 2>/dev/null; } # sj <filter>

load_status() { # sets have_status and status_age_s ("" when unknown)
  have_status=0; status_age_s=""
  [ -r "$status" ] && jq -e . "$status" >/dev/null 2>&1 || return 0
  have_status=1
  local g e
  g=$(sj '.generated_at // empty'); e=$(date -d "$g" +%s 2>/dev/null)
  [ -z "$e" ] && e=$(stat -c %Y "$status" 2>/dev/null)
  [ -n "$e" ] && status_age_s=$(( $(date +%s) - e ))
}
load_status
if [ $have_status -eq 1 ] && { [ -z "$status_age_s" ] || [ "$status_age_s" -ge 60 ]; }; then
  statgen="${HANDOFF_STATUS_GEN:-$(dirname "${BASH_SOURCE[0]}")/operator-status-gen.sh}"
  # HANDOFF_GEN_ACTIVE stops the status generator from calling back into this script
  [ -x "$statgen" ] && HANDOFF_GEN_ACTIVE=1 timeout 2 "$statgen" >/dev/null 2>&1
  load_status
fi

present() { # present <key> — 0 when status.json carries a non-null .key
  [ $have_status -eq 1 ] && jq -e ".$1 != null" "$status" >/dev/null 2>&1
}
age_txt=n/a; [ $have_status -eq 1 ] && [ -n "$status_age_s" ] && age_txt="${status_age_s}s"
section() { printf '\n## %s (%s)\n' "$1" "$2"; }

S='~/.cache/operator/status.json'

render() {
  echo "# Generated handoff"
  section "Generated" "date; hostname; $S generated_at"
  echo "Generated: $(date '+%-I:%M %P %m-%d') on $(hostname -s 2>/dev/null), status age ${age_txt}"

  section "Runs" "$S .runs; sqlite3 -readonly ~/.local/state/wm-build/state.db runs"
  if present runs; then
    jq -r '.runs | if length==0 then "open: none" else .[] | "open: \(.id) \(.slug) \(.stage) \(.age_min)m \(.mode // "")" end' "$status" 2>/dev/null | head -n 12
  else
    echo "open: $NOHOST"
  fi
  if [ -r "$db" ]; then
    ended=$(timeout 1 sqlite3 -readonly "$db" "select id||' '||slug||' outcome='||coalesce(outcome,'-')||' cause='||coalesce(close_cause,'-') from runs where ended > strftime('%Y-%m-%dT%H:%M:%S','now','-1 day') order by id desc limit 11" 2>/dev/null)
    if [ -z "$ended" ]; then echo "ended 24h: none"
    else
      printf '%s\n' "$ended" | head -n 10 | sed 's/^/ended 24h: /'
      [ "$(printf '%s\n' "$ended" | wc -l)" -gt 10 ] && echo "ended 24h: (more not shown)"
    fi
  else
    echo "ended 24h: $NOHOST"
  fi

  section "Queue" "$S .queue"
  if present queue; then
    jq -r '.queue | "admitted: \(.admitted|length) slots=\(.slots // "-")", (.skipped[]? | "skipped \(.reason): \(.slugs|length)")' "$status" 2>/dev/null | head -n 12
  else
    echo "Queue: $NOHOST"
  fi

  section "Decisions open" "$S .decisions_open"
  if present decisions_open; then
    jq -r '.decisions_open | if length==0 then "none" else .[] | "\(.id) \(.slug) \(.cause) opened \(.opened)" end' "$status" 2>/dev/null | head -n 10
  else
    echo "Decisions: $NOHOST"
  fi

  section "Versions" "$S .daemon; $mc_url; git -C ~/repos/synthorg describe"
  if present daemon; then
    jq -r '.daemon | "wm-build daemon \(.running_version // "?") binary \(.binary.version // "?") swapped_after_start=\(.swapped_after_start)"' "$status" 2>/dev/null
  else
    echo "wm-build: $NOHOST"
  fi
  wait "$mc_pid" 2>/dev/null
  mcv=$(jq -r 'select(.version) | "\(.version) (git \(.git_sha // "?"))"' "$mc_tmp" 2>/dev/null)
  [ -n "$mcv" ] && echo "mcphost prod: $mcv" || echo "mcphost prod: unreachable"
  if [ -d "$syn_repo/.git" ] || [ -f "$syn_repo/.git" ]; then
    tag=$(timeout 1 git -C "$syn_repo" describe --tags --abbrev=0 HEAD 2>/dev/null)
    echo "synthorg (local clone HEAD tag): ${tag:-none}"
  else
    echo "synthorg: $NOHOST"
  fi

  section "Chain" "$S .chain"
  if present chain && jq -e '.chain.chain_run_id != null' "$status" >/dev/null 2>&1; then
    jq -r '.chain | "newest: \(.chain_run_id) \(.link) \(.status) \(.ts) host=\(.host // "?")", (if .progress then "progress: \(.progress|tojson|.[0:160])" else empty end)' "$status" 2>/dev/null
  else
    echo "Chain: $NOHOST"
  fi

  section "Sessions alive" "$S .siblings"
  if present siblings; then
    jq -r '.siblings | if length==0 then "none" else .[] | "\(.session_id) \(.skill // "-") \(.prd // "-") since \(.since // "-")" end' "$status" 2>/dev/null | head -n 8
  else
    echo "Sessions: $NOHOST"
  fi

  section "Config" "$S .config"
  if present config; then
    jq -r '.config | "file_mtime \(.file_mtime // "-") loaded_at \(.effective_loaded_at) restart_required=\(.restart_required)"' "$status" 2>/dev/null
  else
    echo "Config: $NOHOST"
  fi
}

mkdir -p "$(dirname "$out")" 2>/dev/null
tmp="$out.tmp.$$"
render >"$tmp" 2>/dev/null && mv -f "$tmp" "$out"
rm -f "$tmp" 2>/dev/null

# R4: index line as line 2 of MEMORY.md, once; no other line is touched
idx_line='- [GENERATED HANDOFF — read first](handoff-generated.md) — rewritten at every SessionEnd by handoff-gen.sh; the prose handoff keeps decisions and traps only'
mem="$memdir/MEMORY.md"
if [ -f "$mem" ] && ! grep -qF 'handoff-generated.md' "$mem"; then
  mem=$(readlink -f "$mem")
  mtmp="$mem.tmp.$$"
  sed -e '1a\' -e "$idx_line" "$mem" >"$mtmp" 2>/dev/null && mv -f "$mtmp" "$mem"
  rm -f "$mtmp" 2>/dev/null
fi

[ "$mc_tmp" != /dev/null ] && rm -f "$mc_tmp"
exit 0
