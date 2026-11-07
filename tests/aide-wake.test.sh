#!/usr/bin/env bash
# aide-wake (A7, approvals #127): Stop hook blocks once on pending work with no armed wake; check writes the idle alarm and pokes a known pane.
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
W="$here/.local/bin/aide-wake.sh"; H="$here/.claude/hooks/aide-wake-stop.sh"
fail=0; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fail=1; }
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
export AIDE_WAKE_DIR="$t/state" EVENTS_DIR="$t/ev" OWED_NOW_BIN="$t/none" AIDE_WAKE_NOW=100000 AIDE_WAKE_BIN="$W"
mkdir -p "$t/ev" "$t/state"
# G1: turn end needs the bridge unit active + fresh status.json; stubbed here (inactive by default)
printf '#!/bin/sh\ncat %s/unit 2>/dev/null || echo inactive\n' "$t" > "$t/systemctl"; chmod +x "$t/systemctl"; export AIDE_SYSTEMCTL_BIN="$t/systemctl" AIDE_BRIDGE_STATUS="$t/bridge.json"
printf '#!/bin/sh\necho "$@" >> %s/tmux.log\nexit 0\n' "$t" > "$t/tmux"; chmod +x "$t/tmux"; export AIDE_TMUX_BIN="$t/tmux"
bash -n "$W" && bash -n "$H" && ok "bash -n" || bad "bash -n"
"$W" pending >/dev/null && bad "pending with empty inbox" || ok "no pending work with empty inbox"
echo "line from rb" > "$t/ev/aide-events.log"
"$W" pending | grep -q '^inbox:' && ok "unread inbox is pending" || bad "unread inbox is pending"
wsz="$(stat -c %s "$t/ev/aide-events.log")"; echo "$wsz" > "$t/ev/aide-events.cursor"
"$W" pending >/dev/null && bad "read inbox still pending" || ok "cursor at EOF = nothing pending"
echo "more" >> "$t/ev/aide-events.log"
# Stop hook
out="$(echo '{"hook_event_name":"Stop"}' | env -u AIDE_WAKE_NOW WM_SEAT=plain "$H")"; [ -z "$out" ] && ok "non-aide session ignored" || bad "non-aide session ignored"
out="$(echo '{"hook_event_name":"Stop"}' | env -u AIDE_WAKE_NOW WM_SEAT=aide "$H")"
jq -e '.decision=="block"' <<<"$out" >/dev/null 2>&1 && ok "blocks with pending work and no wake" || bad "blocks with pending work and no wake"
out="$(echo '{"hook_event_name":"Stop"}' | env -u AIDE_WAKE_NOW WM_SEAT=ctl "$H")"
jq -e '.decision=="block"' <<<"$out" >/dev/null 2>&1 && ok "WM_SEAT=ctl blocks with pending work and no wake (transition aide|ctl)" || bad "WM_SEAT=ctl blocks with pending work and no wake"
[ -s "$t/state/heartbeat" ] && ok "heartbeat written" || bad "heartbeat written"
out="$(echo '{"stop_hook_active":true}' | env -u AIDE_WAKE_NOW WM_SEAT=aide "$H")"; [ -z "$out" ] && ok "stop_hook_active allows" || bad "stop_hook_active allows"
out="$(echo '{"agent_id":"x"}' | env -u AIDE_WAKE_NOW WM_SEAT=aide "$H")"; [ -z "$out" ] && ok "subagent allowed" || bad "subagent allowed"
echo $(( $(date +%s) + 600 )) > "$t/state/wake-armed"
out="$(echo '{}' | env -u AIDE_WAKE_NOW WM_SEAT=aide "$H")"; jq -e '.decision=="block"' <<<"$out" >/dev/null 2>&1 && ok "armed wake alone no longer allows (G1)" || bad "armed wake alone no longer allows"
echo active > "$t/unit"; printf '{"ts": "%s"}' "$(date -Iseconds)" > "$t/bridge.json"
out="$(echo '{}' | env -u AIDE_WAKE_NOW WM_SEAT=aide "$H")"; [ -z "$out" ] && ok "active bridge unit + fresh status allows" || bad "active bridge unit + fresh status allows"; rm -f "$t/unit"
# arm
rm -f "$t/state/wake-armed"; "$W" arm 20; [ "$(cat "$t/state/wake-armed")" = 101200 ] && ok "arm writes now+20m" || bad "arm writes now+20m"
"$W" arm 0 2>/dev/null && bad "arm 0 refused" || ok "arm 0 refused"
# check: stale heartbeat, wake expired, pending -> idle, no pane = not poked
echo 90000 > "$t/state/heartbeat"; echo 99000 > "$t/state/wake-armed"
"$W" check; jq -e '.idle==true and .poked=="no" and .pane_known==false' "$t/state/aide-idle.json" >/dev/null && ok "idle alarm, no pane = not poked" || bad "idle alarm, no pane"
echo "%7" > "$t/state/pane"; "$W" check
jq -e '.idle==true and .poked=="yes"' "$t/state/aide-idle.json" >/dev/null && grep -q 'send-keys -t %7' "$t/tmux.log" && ok "known pane is poked" || bad "known pane is poked"
echo 99990 > "$t/state/heartbeat"; "$W" check; jq -e '.idle==false' "$t/state/aide-idle.json" >/dev/null && ok "fresh heartbeat clears alarm" || bad "fresh heartbeat clears alarm"
echo 90000 > "$t/state/heartbeat"; echo 200000 > "$t/state/wake-armed"; "$W" check; jq -e '.idle==false' "$t/state/aide-idle.json" >/dev/null && ok "armed wake clears alarm" || bad "armed wake clears alarm"
# registration + launcher
jq -e '[.hooks.Stop[].hooks[] | select(.command=="/home/jsy/.claude/hooks/aide-wake-stop.sh")] | length == 1' "$here/.claude/settings.json" >/dev/null && ok "Stop hook registered once" || bad "Stop hook registered once"
grep -q '^ExecStart=.*aide-wake.sh check' "$here/.config/systemd/user/aide-wake.service" && [ -f "$here/.config/systemd/user/aide-wake.timer" ] && ok "unit + timer present" || bad "unit + timer present"
# launcher: records the pane inside tmux
mkdir -p "$t/home/.config/environment.d"; echo 'CLAUDE_CODE_OAUTH_TOKEN=fake' > "$t/home/.config/environment.d/90-claude-oauth.conf"; echo '{}' > "$t/home/.claude.json"; printf '#!/bin/sh\nexit 0\n' > "$t/claude"; chmod +x "$t/claude"
TMUX=x TMUX_PANE=%9 HOME="$t/home" AIDE_CLAUDE_BIN="$t/claude" AIDE_WAKE_DIR="$t/lp" AIDE_CLAUDE_JSON="$t/home/.claude.json" bash "$here/.local/bin/ctl-launch.sh" >/dev/null 2>&1
[ "$(cat "$t/lp/pane" 2>/dev/null)" = %9 ] && ok "ctl-launch records TMUX_PANE" || bad "ctl-launch records TMUX_PANE"
rm -f "$t/lp/pane"; TMUX=x TMUX_PANE=%8 HOME="$t/home" AIDE_CLAUDE_BIN="$t/claude" AIDE_WAKE_DIR="$t/lp" AIDE_CLAUDE_JSON="$t/home/.claude.json" bash "$here/.local/bin/aide-launch.sh" >/dev/null 2>&1
[ "$(cat "$t/lp/pane" 2>/dev/null)" = %8 ] && ok "aide-launch.sh shim records TMUX_PANE via ctl-launch.sh" || bad "aide-launch.sh shim records TMUX_PANE"
exit $fail
