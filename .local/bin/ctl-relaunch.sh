#!/usr/bin/env bash
# ctl-relaunch.sh <account> [why...] (was aide-relaunch.sh, shim kept; hermes-handover item 2.1): stop the running ctl-seat claude (WM_SEAT=ctl or aide), relaunch it in tmux session `aide` under <account>,
# resuming the same session id (~/.config/aide/session-id) with the resume prompt (~/.config/aide/resume-prompt.tmpl).
# Joe 11-01 1:1x AM "can this aide session switch back to mcphost.dev at 2:10am?" + 1:2x AM "how will you guarantee this?":
# the kill comes FIRST so the old account stops spending even if the relaunch fails; the token is read by ctl-launch.sh
# from the store and never printed. Done-check: ctl-relaunch-check.sh <account>.
set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin"
ACCT="${1:?account}"; shift; WHY="${*:-relaunch}"
SID="$(cat "$HOME/.config/aide/session-id")"
LOG="$HOME/.local/state/aide/relaunch.log"; mkdir -p "$(dirname "$LOG")"
TTY="$(cat "$HOME/.config/aide/joe-tty" 2>/dev/null || true)"
STORE="$HOME/.config/fleet-token/store/$ACCT"
CTL_DIR="$(dirname "$(readlink -f "$0")")"   # sibling ctl-launch.sh (same dir as this script, symlink-resolved)
log(){ echo "$(date +%Y-%m-%dT%H:%M:%S%z) $*" | tee -a "$LOG" >&2; }
note(){ log "$*"; [ -n "$TTY" ] && [ -w "$TTY" ] && printf '\n\033[1m[ctl-relaunch %s]\033[0m %s\n' "$(date +%I:%M%p)" "$*" > "$TTY" 2>/dev/null || true; }
[ -r "$STORE" ] || { note "FAIL no store entry $ACCT; nothing stopped, nothing launched"; exit 64; }
# 1. stop the aide CHANNEL claude only: the pid in ~/.config/aide/channel-pid plus every claude under tmux session =aide
#    (exact name; the aide-chain session also carries WM_SEAT=aide and is never touched). WM_SEAT=ctl or aide matches (transition). Never this script's own tree.
desc(){ local p; for p in $(pgrep -P "$1" 2>/dev/null); do echo "$p"; desc "$p"; done; }
aide_pids(){ { [ -r "$HOME/.config/aide/channel-pid" ] && cat "$HOME/.config/aide/channel-pid";
  for pp in $(tmux list-panes -a -F '#{session_name} #{pane_pid}' 2>/dev/null | awk '$1=="aide"{print $2}'); do echo "$pp"; desc "$pp"; done; } | sort -u | while read -r p; do
  [ -n "$p" ] && [ "$p" != "$$" ] && grep -qa 'claude' "/proc/$p/cmdline" 2>/dev/null && tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -qxE 'WM_SEAT=(ctl|aide)' && echo "$p"; done; }
pids="$(aide_pids | tr '\n' ' ')"
log "stopping aide claude pid(s): ${pids:-none} (account switch to $ACCT: $WHY)"
[ -n "$pids" ] && kill $pids 2>/dev/null
for _ in $(seq 1 20); do [ -z "$(aide_pids)" ] && break; sleep 1; done
left="$(aide_pids | tr '\n' ' ')"; [ -n "$left" ] && { log "SIGKILL leftover $left"; kill -9 $left 2>/dev/null; sleep 1; }
tmux list-sessions -F "#{session_name}" 2>/dev/null | grep -qx aide && tmux kill-session -t aide
# 2. relaunch, resuming the same session, under <account>
EFFORT="$(jq -r '.ctl.effort // .aide.effort // "high"' "$HOME/.config/wm-decide/seat-model-hold.json" 2>/dev/null || echo high)"   # Joe 11-01 "go": effort from the seat-model-hold ctl/aide row (medium trial)
P="$HOME/.local/state/aide/resume-prompt-$(date +%Y%m%d-%H%M%S).txt"
sed -e "s|@ACCT@|$ACCT|g" -e "s|@TIME@|$(date +'%I:%M %p %Z')|g" -e "s|@WHY@|$WHY|g" "$HOME/.config/aide/resume-prompt.tmpl" > "$P"
tmux new-session -d -s aide -x 200 -y 50 -c "$HOME" \
  "exec $CTL_DIR/ctl-launch.sh --account $ACCT --model claude-fable-5-1 --effort $EFFORT --resume $SID \"\$(cat $P)\"" \
  || { note "FAIL tmux new-session for aide under $ACCT (old aide stopped; $ACCT not running)"; exit 70; }
sleep 8
: > "$HOME/.config/aide/channel-pid"
newp="$(aide_pids | tr '\n' ' ')"; [ -n "$newp" ] && echo "$newp" | tr " " "\n" | head -1 > "$HOME/.config/aide/channel-pid"
if [ -n "$newp" ]; then note "aide relaunched under $ACCT, pid(s) $newp, tmux session 'aide' (attach: tmux attach -t aide). Old pid(s): ${pids:-none}."
else note "FAIL aide not running 8 s after relaunch under $ACCT (tmux session 'aide'); old pid(s) ${pids:-none} stopped. See: tmux attach -t aide"; exit 71; fi
seat-event.sh aide "ctl-relaunch.sh: aide relaunched under $ACCT at $(date +%I:%M%p) in tmux 'aide', resumed $SID; stopped ${pids:-none}; why: $WHY" >/dev/null 2>&1 || true
