#!/usr/bin/env bash
# operator-status-card.sh [--json | --section runs|queue|chain|siblings|daemon|config]
# SessionStart banner (PRD dotfiles-operator-status-card R3/R6): renders the
# generated status.json as a <= 25-line card, regenerating it when older than
# 60 s. Fail-open: always exits 0.
set -uo pipefail

cache="${OPERATOR_CACHE_DIR:-$HOME/.cache/operator}"
sj="$cache/status.json"
gen="${OPERATOR_GEN:-$(dirname "${BASH_SOURCE[0]}")/operator-status-gen.sh}"
chain_host="${OPERATOR_CHAIN_HOST:-orch}"

mode=card; section=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) mode=json; shift ;;
    --section) mode=section; section="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

age=-1
if [ -r "$sj" ]; then age=$(( $(date +%s) - $(stat -c %Y "$sj") )); fi
if [ "$age" -lt 0 ] || [ "$age" -gt 60 ]; then
  timeout 5 "$gen" --out "$sj" >/dev/null 2>&1
  [ -r "$sj" ] && age=$(( $(date +%s) - $(stat -c %Y "$sj") ))
fi
[ -r "$sj" ] && jq -e . "$sj" >/dev/null 2>&1 || { echo "operator card: status.json unavailable"; exit 0; }

if [ "$mode" = json ]; then cat "$sj"; exit 0; fi

# t <iso|date string> — 12-hour local clock, "?" when empty/unparseable
t() { [ -n "${1:-}" ] && [ "$1" != null ] && date -d "$1" +'%-I:%M %P' 2>/dev/null || printf '?'; }
j() { jq -r "$1" "$sj" 2>/dev/null; }
src_ok() { [ "$(j ".sources.$1 // \"missing\"")" = ok ]; }

render_runs() {
  if ! src_ok runs; then echo "runs: ?"; return; fi
  local n; n=$(j '.runs|length')
  echo "runs: $n open"
  local iw gw
  iw=$(j '.config.wall_minutes.inner // empty'); gw=$(j '.config.wall_minutes.gate // empty')
  j '.runs[0:10][] | [.id,.slug,(.stage//"?"),(.age_min//"?")] | @tsv' | while IFS=$'\t' read -r id slug stage age_min; do
    # inner-stage runs answer to [inner] wall_minutes, every later stage to [gate]
    local wall="$gw"; [ "$stage" = inner ] && wall="$iw"
    local over=""
    [ -n "$wall" ] && [ "$age_min" != "?" ] && [ "$age_min" -gt "$wall" ] && over=" OVER-WALL"
    echo "  $id $slug $stage ${age_min}m$over"
  done
  [ "$n" -gt 10 ] && echo "  +$((n-10)) more"
}
render_queue() {
  if ! src_ok queue; then echo "queue: ?"; return; fi
  local adm skp
  adm=$(j '.queue.admitted|length')
  skp=$(j '.queue.skipped | map({r:(.reason|split(":")[0]), n:(.slugs|length)}) | group_by(.r) | map("\(.[0].r) \(map(.n)|add)") | join(", ")')
  echo "queue: admit $adm${skp:+, $skp}"
}
render_decisions() {
  src_ok decisions || { echo "decisions: ?"; return; }
  echo "decisions: $(j '.decisions_open|length') open$(j '.decisions_open[0:3] | map(" " + (.id|tostring) + ":" + (.cause//"?")) | join(",")')"
}
render_chain() {
  if ! src_ok chain; then echo "chain: not on this host ($(j '.chain.host // empty' | grep . || echo "$chain_host"))"; return; fi
  echo "chain: $(j '.chain|"\(.chain_run_id) \(.link) \(.status)"') at $(t "$(j '.chain.ts')")"
}
render_siblings() {
  if ! src_ok siblings; then echo "siblings: ?"; return; fi
  local n; n=$(j '.siblings|length')
  if [ "$n" -eq 0 ]; then echo "siblings: none"; return; fi
  local out="" sid skill prd since
  while IFS=$'\t' read -r sid skill prd since; do
    out="${out:+$out; }$sid /$skill ($prd) since $(t "$since")"
  done < <(j '.siblings[0:3][] | [.session_id, (.skill//"?"), (.prd//"?"), (.since//"")] | @tsv')
  echo "siblings: $out"
}
render_daemon() {
  if ! src_ok daemon; then echo "daemon: ?"; return; fi
  local sw=""
  [ "$(j '.daemon.swapped_after_start')" = true ] && sw="swapped after start, "
  echo "daemon $(j '.daemon.running_version // "?"') started $(t "$(j '.daemon.started_at')") · binary $(j '.daemon.binary.version // "?"') (${sw}$(t "$(j '.daemon.binary.mtime')"))"
}
render_config() {
  if ! src_ok config; then echo "config: ?"; return; fi
  echo "config: file $(t "$(j '.config.file_mtime')") · loaded $(t "$(j '.config.effective_loaded_at')") · tick $(t "$(j '.config.tick_loaded_at')") · restart-required $(j '.config.restart_required // "?"')"
}

if [ "$mode" = section ]; then
  case "$section" in
    runs|queue|chain|siblings|daemon|config) "render_$section" ;;
    *) echo "operator card: unknown section '$section'" ;;
  esac
  exit 0
fi

echo "operator card ($(j '.host // "?"'))"
render_runs; render_queue; render_decisions; render_chain; render_siblings; render_daemon; render_config
echo "status.json generated ${age}s ago"
exit 0
