#!/usr/bin/env bash
# ctl-relaunch-check.sh <account> (was aide-relaunch-check.sh, shim kept): OK when a ctl-seat claude (WM_SEAT=ctl or aide) runs and its token equals store/<account> by sha256 (never printed).
set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin"
ACCT="${1:?account}"; TTY="$(cat "$HOME/.config/aide/joe-tty" 2>/dev/null || true)"; LOG="$HOME/.local/state/aide/relaunch.log"
want="$(tr -d '\n' < "$HOME/.config/fleet-token/store/$ACCT" | sha256sum | cut -c1-16)"
ok=0; seen=0
desc(){ local p; for p in $(pgrep -P "$1" 2>/dev/null); do echo "$p"; desc "$p"; done; }
for p in $({ cat "$HOME/.config/aide/channel-pid" 2>/dev/null; for pp in $(tmux list-panes -a -F '#{session_name} #{pane_pid}' 2>/dev/null | awk '$1=="aide"{print $2}'); do echo "$pp"; desc "$pp"; done; } | sort -u); do
  grep -qa claude "/proc/$p/cmdline" 2>/dev/null || continue
  env="$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null)" || continue
  grep -qxE 'WM_SEAT=(ctl|aide)' <<<"$env" || continue
  seen=$((seen+1))
  have="$(grep -m1 '^CLAUDE_CODE_OAUTH_TOKEN=' <<<"$env" | cut -d= -f2- | tr -d '\n' | sha256sum | cut -c1-16)"
  [ "$have" = "$want" ] && ok=$((ok+1))
done
tm="$(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep -qx aide && echo yes || echo no)"
if [ "$ok" -gt 0 ]; then line="OK aide running under $ACCT ($ok of $seen aide pid(s) match store hash; tmux aide=$tm) $(date +%I:%M%p)"
else line="FAIL aide not running under $ACCT ($seen aide pid(s), 0 match store hash; tmux aide=$tm) $(date +%I:%M%p)"; fi
echo "$(date +%Y-%m-%dT%H:%M:%S%z) check: $line" >> "$LOG"; echo "$line"
seat-event.sh aide "ctl-relaunch-check: $line" >/dev/null 2>&1 || true
[ "$ok" -gt 0 ] || { [ -n "$TTY" ] && [ -w "$TTY" ] && printf '\n\033[1m[ctl-relaunch-check]\033[0m %s\n' "$line" > "$TTY" 2>/dev/null; exit 1; }
