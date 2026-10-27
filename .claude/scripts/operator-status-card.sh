#!/usr/bin/env bash
# operator-status-card.sh [--json | --section runs|queue|seats|timers|floor|chain|siblings|daemon|config]
# SessionStart banner (PRD dotfiles-operator-status-card R3/R6): renders the
# generated status.json as a <= 25-line card, regenerating it when older than
# 60 s. Fail-open: always exits 0.
set -uo pipefail

cache="${OPERATOR_CACHE_DIR:-$HOME/.cache/operator}"
sj="$cache/status.json"
gen="${OPERATOR_GEN:-$(dirname "${BASH_SOURCE[0]}")/operator-status-gen.sh}"
chain_host="${OPERATOR_CHAIN_HOST:-orch}"
# seat correction rates: fleet-dash's status.json (decisions.per_agent from swarm-decide's stats.json, alarms[] from collect.sh)
fleet_sj="${OPERATOR_FLEET_STATUS:-$HOME/.cache/fleet-dash/status.json}"
seats="${OPERATOR_SEATS:-rb r7 controller}"

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
  j '"queue: \(.queue.queue_total // "?") (building \(.queue.building // "?"), ready \(.queue.queue_ready // "?")" + (if .queue.blocked != null then ", blocked \(.queue.blocked)" else "" end) + (if .queue.parked != null then ", parked \(.queue.parked)" else "" end) + ")"'
}
render_decisions() {
  src_ok decisions || { echo "decisions: ?"; return; }
  echo "decisions: $(j '.decisions_open|length') open$(j '.decisions_open[0:3] | map(" " + (.id|tostring) + ":" + (.cause//"?")) | join(",")')"
}
render_seats() {
  # per seat: corrected/n over its last 20 own decisions (mixed models), the current-model run when it is under 20 rows, the hold or flag state; then every seat-* / verifier-rate alarm
  if [ ! -r "$fleet_sj" ] || ! jq -e '.decisions.per_agent' "$fleet_sj" >/dev/null 2>&1; then echo "seats: ?"; return; fi
  echo "seats (corrected/n last 20, share):"
  local name c n share thr flag held exp nc model since status jt line
  while IFS=$'\t' read -r name c n share thr flag held exp nc model since status jt; do
    # swarm-decide judged_text ("unmeasured (judged k/n)") = fewer than MIN_JUDGED judged rows in the window: print it in place of the share
    if [ "$jt" != "-" ]; then line="  $name $c/$n $jt"; else line="  $name $c/$n $share"; [ "$thr" = true ] && line="$line at threshold"; fi
    if [ "$status" = unmeasured ] && [ "$nc" != "?" ]; then line="$line ($nc on $model since $(t "$since"), unmeasured until 20)"
    elif [ "$nc" != "?" ] && [ "$model" != "?" ]; then line="$line ($nc on $model since $(t "$since"))"; fi
    if [ "$held" != "-" ]; then line="$line · held until $held"
    elif [ "$flag" = true ] && [ "$exp" = true ]; then line="$line · hold expired, flag up, awaiting Joe"
    elif [ "$flag" = true ]; then line="$line · UPGRADE flag up"; fi
    echo "$line"
  done < <(jq -r --arg seats "$seats" '.decisions.per_agent as $p | ($seats|split(" "))[] | select($p[.] != null) | . as $k | $p[$k] |
    [$k, (.corrected_all // .corrected20 // "?"), (.n20_all // .n20 // "?"), (.share // "n/a"), (.share == 0.25), (.upgrade_flag // "null"), (.held_until // "-"),
     ((.hold_expired // false) or (.hold_expired_flag_up // false)), (.n_current // "?"), (.current_model // "?"), (.current_since // "?"), (.status // "?"), (.judged_text // "-")] | map(tostring) | join("\t")' "$fleet_sj" 2>/dev/null)
  jq -r '(.alarms // []) | map(select((.text // "") | test("^(seat-|verifier-rate)"))) | .[0:6][] | "  " + .text' "$fleet_sj" 2>/dev/null
}
render_timers() {
  # fleet-dash status.json `timers_stalled` (user timers with no NEXT / stale LAST / inactive, all three hosts; five-whys 2026-10-24): ok, the stalled list, or ? when the field is absent
  if [ ! -r "$fleet_sj" ] || ! jq -e 'has("timers_stalled")' "$fleet_sj" >/dev/null 2>&1; then echo "timers: ?"; return; fi
  if jq -e '.timers_stalled | length == 0' "$fleet_sj" >/dev/null 2>&1; then echo "timers: ok"; return; fi
  jq -r '.timers_stalled | "timers: STALLED " + (length|tostring) + " (" + ([.[0:6][] | "\(.host) \(.unit) \(.reason)"] | join(", ")) + ")"' "$fleet_sj" 2>/dev/null | cut -c1-400 || echo "timers: ?"
}
render_floor() {
  # M9 seat floor (seat-floor-probe.sh -> seat-floor.json): post-compaction context floor p50 of the last 5 boundaries per seat + SessionStart hook cancellations in 24 h;
  # prints nothing until the probe has run (a host without the probe keeps today's card).
  local ff="${OPERATOR_SEAT_FLOOR:-$HOME/.cache/fleet-dash/seat-floor/seat-floor.json}"
  [ -r "$ff" ] && jq -e '.seats | length > 0' "$ff" >/dev/null 2>&1 || return 0
  jq -r '"floor (p50 last 5): " + ([.seats | to_entries[] | "\(.key) \(if .value.floor_p50 == null then "?" else ((.value.floor_p50 / 1000 * 10 | round) / 10 | tostring) + "K" end)\(if (.value.compact_hook_cancelled_24h // 0) > 0 then " (" + (.value.compact_hook_cancelled_24h | tostring) + " hook cancels 24h)" else "" end)"] | join(" · ")) + " · stage " + ((.stage // 0) | tostring)' "$ff" 2>/dev/null | cut -c1-240
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
    runs|queue|seats|timers|floor|chain|siblings|daemon|config) "render_$section" ;;
    *) echo "operator card: unknown section '$section'" ;;
  esac
  exit 0
fi

echo "operator card ($(j '.host // "?"'))"
render_runs; render_queue; render_decisions; render_seats; render_timers; render_floor; render_chain; render_siblings; render_daemon; render_config
echo "status.json generated ${age}s ago"
exit 0
