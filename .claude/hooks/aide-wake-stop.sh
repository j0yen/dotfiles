#!/usr/bin/env bash
# aide-wake-stop.sh: Stop hook, carbon executor seat only (WM_SEAT=aide or ctl). Joe 10-31 10:33 AM "NEVER EVER BE IDLE", approvals #127; open-asks A7.
# Records the turn end (heartbeat). Blocks the turn end ONCE when the aide has pending work (unread inbox lines, DELAY/OVERDUE rows) and no live
# wake is armed (aide-wake.sh arm <minutes>, called after CronCreate). stop_hook_active true = allow (one block per turn). Subagents are never blocked.
# Any failure allows. Env: AIDE_WAKE_BIN (default ~/.local/bin/aide-wake.sh), AIDE_WAKE_DIR.
set -u
case "${WM_SEAT:-}" in aide|ctl) ;; *) exit 0 ;; esac
in="$(cat 2>/dev/null)"
command -v jq >/dev/null 2>&1 || exit 0
[ -z "$(jq -r '.agent_id // empty' <<<"$in" 2>/dev/null)" ] || exit 0
bin="${AIDE_WAKE_BIN:-$HOME/.local/bin/aide-wake.sh}"
[ -x "$bin" ] || { echo "aide-wake-stop: $bin missing, allowing" >&2; exit 0; }
"$bin" beat 2>/dev/null
[ "$(jq -r '.stop_hook_active // false' <<<"$in" 2>/dev/null)" = true ] && exit 0
why="$("$bin" pending 2>/dev/null)" || exit 0
d="${AIDE_WAKE_DIR:-$HOME/.cache/aide}"
armed="$(head -c 20 "$d/wake-armed" 2>/dev/null)"; [[ "$armed" =~ ^[0-9]+$ ]] || armed=0
[ "$armed" -gt "$(date +%s)" ] && exit 0
jq -nc --arg r "Aide has pending work and no wake armed ($(tr '\n' ' ' <<<"$why")). Work it, or arm a wake: CronCreate a sweep, then run aide-wake.sh arm <minutes>." '{decision:"block",reason:$r}'
exit 0
