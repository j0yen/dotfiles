#!/usr/bin/env bash
# aide-account-follow.sh: the aide session follows the FLEET account (Joe 11-01 1:5x PM "be sure to move this session and
# the entire fleet to jyen.tech after mcphost.dev depletes", approvals #207). The fleet account switch is the quota watcher's
# ring rotation (fleet-token-429-watch.sh -> fleet-token-rotate.sh); this timer makes the AIDE account switch follow it:
# when ~/.cache/fleet-dash/token.json .account differs from the account the running aide claude holds (store hash, never
# printed), run aide-relaunch.sh <fleet account> (kill first, resume the same session id). One relaunch per 20 min at most.
# Dry run: AAF_DRY=1. State: ~/.local/state/aide/follow.log + follow.stamp.
set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin"
ST="$HOME/.local/state/aide"; mkdir -p "$ST"; LOG="$ST/follow.log"; STAMP="$ST/follow.stamp"
TOK="${AAF_TOKEN_JSON:-$HOME/.cache/fleet-dash/token.json}"
fleet="$(jq -r '.account // empty' "$TOK" 2>/dev/null)"
[ -n "$fleet" ] || { echo "$(date +%FT%T%z) no fleet account in $TOK" >> "$LOG"; exit 0; }
store="$HOME/.config/fleet-token/store/$fleet"
[ -r "$store" ] || { echo "$(date +%FT%T%z) fleet=$fleet has no store entry: nothing to follow" >> "$LOG"; exit 0; }
want="$(tr -d '\n' < "$store" | sha256sum | cut -c1-16)"
desc(){ local p; for p in $(pgrep -P "$1" 2>/dev/null); do echo "$p"; desc "$p"; done; }
seen=0; ok=0
for p in $({ cat "$HOME/.config/aide/channel-pid" 2>/dev/null; for pp in $(tmux list-panes -a -F '#{session_name} #{pane_pid}' 2>/dev/null | awk '$1=="aide"{print $2}'); do echo "$pp"; desc "$pp"; done; } | sort -u); do
  grep -qa claude "/proc/$p/cmdline" 2>/dev/null || continue
  env="$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null)" || continue
  grep -qx 'WM_SEAT=aide' <<<"$env" || continue
  seen=$((seen+1))
  have="$(grep -m1 '^CLAUDE_CODE_OAUTH_TOKEN=' <<<"$env" | cut -d= -f2- | tr -d '\n' | sha256sum | cut -c1-16)"
  [ "$have" = "$want" ] && ok=$((ok+1))
done
[ "$seen" -gt 0 ] || { echo "$(date +%FT%T%z) no aide claude running: nothing to follow (fleet=$fleet)" >> "$LOG"; exit 0; }
[ "$ok" -eq 0 ] || exit 0   # aide already on the fleet account
now=$(date +%s); last=$(cat "$STAMP" 2>/dev/null || echo 0)
if [ $((now - last)) -lt 1200 ]; then echo "$(date +%FT%T%z) aide not on fleet=$fleet but a relaunch ran $(( (now-last)/60 )) min ago: wait" >> "$LOG"; exit 0; fi
echo "$(date +%FT%T%z) aide ($seen pid) not on fleet account $fleet: aide account switch -> aide-relaunch.sh $fleet" >> "$LOG"
[ "${AAF_DRY:-0}" = 1 ] && { echo "DRY: aide-relaunch.sh $fleet"; exit 0; }
echo "$now" > "$STAMP"
seat-event.sh aide "aide-account-follow $(date +%I:%M%p): fleet account is $fleet, the aide was not on it: aide account switch running (aide-relaunch.sh $fleet); check aide-relaunch-check.sh $fleet" >/dev/null 2>&1 || true
exec "$HOME/.local/bin/aide-relaunch.sh" "$fleet" "follow the fleet account switch (Joe 11-01 1:5x PM, approvals #207)"
