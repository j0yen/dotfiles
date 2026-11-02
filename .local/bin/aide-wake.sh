#!/usr/bin/env bash
# aide-wake.sh: the aide never idles (Joe 10-31 10:33 AM "NEVER EVER BE IDLE", approvals #127; open-asks A7).
# The aide session is not in tmux unless aide-launch.sh ran with AIDE_TMUX=1, so a wake has two forms: a tmux poke (pane known) and, always,
# an aide-idle alarm file the collector and aide-inbox.sh can show. State dir $AIDE_WAKE_DIR (default ~/.cache/aide):
#   wake-armed   epoch of the aide's next in-session wake (CronCreate), written by `arm`
#   heartbeat    epoch of the aide's last turn end, written by `beat` (Stop hook)
#   pane         tmux target of the aide pane, written by aide-launch.sh when it runs inside tmux
#   aide-idle.json  alarm written by `check`: {"idle":bool,...}
# Modes:
#   arm <minutes>   record that a wake fires in <minutes> minutes
#   beat            record a turn end
#   pending         print the pending-work lines (unread aide inbox lines, aide DELAY/OVERDUE rows); exit 0 when there is some, 1 when none
#   check           timer entry: pending work + heartbeat older than AIDE_IDLE_MIN (default 30) + no live armed wake = idle: write the alarm,
#                   poke the pane by tmux when one is recorded; otherwise clear the alarm. Always exit 0.
# Env: AIDE_WAKE_DIR EVENTS_DIR (inbox, default ~/.cache/fleet-dash) OWED_NOW_BIN OPEN_ASKS AIDE_IDLE_MIN AIDE_WAKE_NOW (epoch, tests) AIDE_TMUX_BIN
set -u
D="${AIDE_WAKE_DIR:-$HOME/.cache/aide}"
EV="${EVENTS_DIR:-${FLEET_DASH_DIR:-$HOME/.cache/fleet-dash}}"
now() { printf '%s' "${AIDE_WAKE_NOW:-$(date +%s)}"; }
num() { [[ "${1:-}" =~ ^[0-9]{1,12}$ ]] && printf '%s' "$1" || printf 0; }
rd() { num "$(head -c 20 "$D/$1" 2>/dev/null)"; }

pending() {
  local log="$EV/aide-events.log" cur="$EV/aide-events.cursor" size off own out n=0
  if [ -f "$log" ]; then
    size="$(stat -c %s "$log" 2>/dev/null || echo 0)"; off="$(num "$(head -c 20 "$cur" 2>/dev/null)")"
    [ "$off" -gt "$size" ] && off=0
    [ "$size" -gt "$off" ] && { echo "inbox: $((size - off)) unread byte(s) in aide-events.log"; n=1; }
  fi
  own="${OWED_NOW_BIN:-$HOME/.claude/hooks/owed-now.sh}"
  if [ -x "$own" ]; then
    out="$("$own" lint --seat aide 2>/dev/null)" || { echo "owed: $(printf '%s\n' "$out" | grep -c .) DELAY/OVERDUE row(s) for aide"; n=1; }
  fi
  [ "$n" = 1 ]
}

case "${1:-}" in
  arm)  m="$(num "${2:-}")"; [ "$m" -gt 0 ] || { echo "aide-wake: arm needs minutes > 0" >&2; exit 2; }
        mkdir -p "$D" && printf '%s\n' "$(( $(now) + m * 60 ))" > "$D/wake-armed" ;;
  beat) mkdir -p "$D" && printf '%s\n' "$(now)" > "$D/heartbeat" ;;
  pending) pending; exit $? ;;
  check)
    mkdir -p "$D"; t="$(now)"; lim="$(num "${AIDE_IDLE_MIN:-30}")"; [ "$lim" -gt 0 ] || lim=30
    armed="$(rd wake-armed)"; hb="$(rd heartbeat)"; age=$(( t - hb ))
    pending >/dev/null; has=$?
    if [ "$has" = 0 ] && [ "$armed" -le "$t" ] && [ "$age" -ge $((lim * 60)) ]; then
      poked=no; pane="$(head -c 100 "$D/pane" 2>/dev/null | tr -d '\n')"
      if [[ "$pane" =~ ^[A-Za-z0-9_.:@%-]+$ ]] && "${AIDE_TMUX_BIN:-tmux}" has-session -t "$pane" 2>/dev/null; then
        "${AIDE_TMUX_BIN:-tmux}" send-keys -t "$pane" "aide wake: pending work, work the owed list" Enter 2>/dev/null && poked=yes
      fi
      printf '{"idle":true,"since_epoch":%s,"idle_min":%s,"poked":"%s","pane_known":%s}\n' "$hb" "$((age / 60))" "$poked" "$([ -n "$pane" ] && echo true || echo false)" > "$D/aide-idle.json"
    else
      printf '{"idle":false}\n' > "$D/aide-idle.json"
    fi ;;
  *) echo "usage: aide-wake.sh arm <minutes> | beat | pending | check" >&2; exit 2 ;;
esac
exit 0
