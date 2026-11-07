#!/usr/bin/env bash
# aide-wake-stop.sh: Stop hook, carbon executor seat only (WM_SEAT=aide or ctl). Joe 10-31 10:33 AM "NEVER EVER BE IDLE", approvals #127; open-asks A7.
# Records the turn end (heartbeat). Blocks the turn end ONCE when the aide has pending work (unread inbox lines, DELAY/OVERDUE rows) and no live
# wake is armed (aide-wake.sh arm <minutes>, called after CronCreate). stop_hook_active true = allow (one block per turn). Subagents are never blocked.
# Any failure allows. Env: AIDE_WAKE_BIN (default ~/.local/bin/aide-wake.sh), AIDE_WAKE_DIR.
# Turn-end credential (five-whys G1, 11-06): the event-bridge unit is ACTIVE and its status.json ts is < 10 min old. The wake-armed lease is
# no longer a credential (the 8:26 PM turn ended on a lease 2 min after the waiter exited). Env: AIDE_SYSTEMCTL_BIN, AIDE_BRIDGE_STATUS, AIDE_BRIDGE_MAX_AGE_S (600).
set -u
case "${WM_SEAT:-}" in aide|ctl) ;; *) exit 0 ;; esac
in="$(cat 2>/dev/null)"
command -v jq >/dev/null 2>&1 || exit 0
[ -z "$(jq -r '.agent_id // empty' <<<"$in" 2>/dev/null)" ] || exit 0
bin="${AIDE_WAKE_BIN:-$HOME/.local/bin/aide-wake.sh}"
[ -x "$bin" ] || { echo "aide-wake-stop: $bin missing, allowing" >&2; exit 0; }
"$bin" beat 2>/dev/null
[ "$(jq -r '.stop_hook_active // false' <<<"$in" 2>/dev/null)" = true ] && exit 0
sc="${AIDE_SYSTEMCTL_BIN:-systemctl}"
st="${AIDE_BRIDGE_STATUS:-$HOME/.cache/aide/event-bridge/status.json}"
max="${AIDE_BRIDGE_MAX_AGE_S:-600}"
bad=""
if [ "$("$sc" --user is-active ctl-event-bridge.service 2>/dev/null)" != active ]; then bad="ctl-event-bridge.service is not active"
else
  tsv="$(jq -r '.ts // empty' "$st" 2>/dev/null)"; tse="$(date -d "$tsv" +%s 2>/dev/null)" || tse=""
  if [ -z "$tse" ]; then bad="event-bridge status.json has no readable ts"
  elif [ $(( $(date +%s) - tse )) -ge "$max" ]; then bad="event-bridge status.json ts $tsv is older than $((max/60)) min"; fi
fi
[ -z "$bad" ] && exit 0
why="$("$bin" pending 2>/dev/null)" || why="no pending work listed"
r="Turn end refused: $bad, so nothing will wake this seat ($(tr '\n' ' ' <<<"$why")). Restart the unit (systemctl --user restart ctl-event-bridge.service) and confirm status.json ts moves; a wake-armed lease is not a substitute."
if [ "${WM_DIRECTOR:-}" = hermes ]; then printf 'director=hermes report-not-block: %s\n' "$(tr '\n' ' ' <<<"$r")"; else jq -nc --arg r "$r" '{decision:"block",reason:$r}'; fi
exit 0
