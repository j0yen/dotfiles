#!/usr/bin/env bash
# ctl-account-follow.sh (was aide-account-follow.sh, shim kept; the systemd unit still names the shim): the ctl seat session follows the FLEET account (Joe 11-01 1:5x PM "be sure to move this session and
# the entire fleet to jyen.tech after mcphost.dev depletes", approvals #207). The fleet account switch is the quota watcher's
# ring rotation (fleet-token-429-watch.sh -> fleet-token-rotate.sh); this timer makes the AIDE account switch follow it:
# when ~/.cache/fleet-dash/token.json .account differs from the account the running aide claude holds (store hash, never
# printed), run ctl-relaunch.sh <fleet account> (kill first, resume the same session id). One relaunch per 20 min at most.
# Dry run: AAF_DRY=1. State: ~/.local/state/aide/follow.log + follow.stamp.
set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin"
ST="$HOME/.local/state/aide"; mkdir -p "$ST"; LOG="$ST/follow.log"; STAMP="$ST/follow.stamp"
TOK="${AAF_TOKEN_JSON:-$HOME/.cache/fleet-dash/token.json}"
fleet="$(jq -r '.account // empty' "$TOK" 2>/dev/null)"
[ -n "$fleet" ] || { echo "$(date +%FT%T%z) no fleet account in $TOK" >> "$LOG"; exit 0; }
store="$HOME/.config/fleet-token/store/$fleet"
[ -r "$store" ] || { echo "$(date +%FT%T%z) fleet=$fleet has no store entry: nothing to follow" >> "$LOG"; exit 0; }
# A1300: the fleet account may be a Fable-lane account (mcphost.dev) that ctl's non-Fable model must not use; follow only an account the lane policy permits and has
# not exhausted. Installed tool + missing/unreadable policy = do not follow (fail closed, F3); a genuinely legacy tree (no tool, no policy) follows as before.
_here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
_gate="$_here/../lib/account-lane-gate.sh"; [ -r "$_gate" ] || _gate="$HOME/.local/lib/account-lane-gate.sh"
if [ -r "$_gate" ]; then . "$_gate"; else al_gate_state() { if [ -e "${ACCOUNT_LANE_PY:-$HOME/.local/lib/account-lane.py}" ] || [ -n "${ACCOUNT_LANE_POLICY:-}" ]; then echo broken; else echo legacy; fi; }; al_gate_why() { echo "account lane gate library missing while the lane tool is installed"; }; fi
case "$(al_gate_state)" in
  broken) echo "$(date +%FT%T%z) WARNING: $(al_gate_why) -- not following fleet=$fleet" >> "$LOG"; exit 0 ;;
  enforced)
    _al="$_here/../lib/account-lane.py"; [ -r "$_al" ] || _al="$HOME/.local/lib/account-lane.py"
    if [ ! -r "$_al" ] || ! python3 -I "$_al" check --account "$fleet" --model claude-sonnet-5-5 >/dev/null; then
      echo "$(date +%FT%T%z) fleet=$fleet is not usable by ctl's lane (policy/exhaustion): not following, ctl stays on its account" >> "$LOG"; exit 0
    fi ;;
esac
want="$(tr -d '\n' < "$store" | sha256sum | cut -c1-16)"
desc(){ local p; for p in $(pgrep -P "$1" 2>/dev/null); do echo "$p"; desc "$p"; done; }
seen=0; ok=0
for p in $({ cat "$HOME/.config/aide/channel-pid" 2>/dev/null; for pp in $(tmux list-panes -a -F '#{session_name} #{pane_pid}' 2>/dev/null | awk '$1=="aide"{print $2}'); do echo "$pp"; desc "$pp"; done; } | sort -u); do
  grep -qa claude "/proc/$p/cmdline" 2>/dev/null || continue
  env="$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null)" || continue
  grep -qxE 'WM_SEAT=(ctl|aide)' <<<"$env" || continue
  seen=$((seen+1))
  have="$(grep -m1 '^CLAUDE_CODE_OAUTH_TOKEN=' <<<"$env" | cut -d= -f2- | tr -d '\n' | sha256sum | cut -c1-16)"
  [ "$have" = "$want" ] && ok=$((ok+1))
done
[ "$seen" -gt 0 ] || { echo "$(date +%FT%T%z) no aide claude running: nothing to follow (fleet=$fleet)" >> "$LOG"; exit 0; }
[ "$ok" -eq 0 ] || exit 0   # aide already on the fleet account
now=$(date +%s); last=$(cat "$STAMP" 2>/dev/null || echo 0)
if [ $((now - last)) -lt 1200 ]; then echo "$(date +%FT%T%z) aide not on fleet=$fleet but a relaunch ran $(( (now-last)/60 )) min ago: wait" >> "$LOG"; exit 0; fi
echo "$(date +%FT%T%z) aide ($seen pid) not on fleet account $fleet: aide account switch -> ctl-relaunch.sh $fleet" >> "$LOG"
# hold gate (hermes-handover 2.4): the relaunch step only; the account read/compare above still runs so status lines keep working
"$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/hold-gate.sh" aide-account-follow || exit 1
[ "${AAF_DRY:-0}" = 1 ] && { echo "DRY: ctl-relaunch.sh $fleet"; exit 0; }
echo "$now" > "$STAMP"
seat-event.sh aide "aide-account-follow $(date +%I:%M%p): fleet account is $fleet, the aide was not on it: aide account switch running (ctl-relaunch.sh $fleet); check ctl-relaunch-check.sh $fleet" >/dev/null 2>&1 || true
# A1577 wiring (candidate, uninstalled): when WM_SUCC_ASK names the canonical task, mint the planned invocation and bind it; a producer refusal
# (no applied effect row, UNKNOWN prior, spent id) leaves the relaunch UNVERIFIED and unbound, never blocked and never claimed equivalent.
if [ -n "${WM_SUCC_ASK:-}" ] && [ -r "$HOME/.local/lib/a1577_produce.py" ]; then
  _inv="${WM_SUCC_INV:-rl-$(date +%Y%m%d-%H%M%S)-$(python3 -I -c 'import secrets;print(secrets.token_hex(8))')}"   # W1: an effect owner plans WM_SUCC_INV and records the effect against it first; without one the id is random and the producer refuses (UNVERIFIED)
  _out="$HOME/.local/state/aide/succ-bind"; mkdir -p "$_out"
  if _env="$(python3 -I "$HOME/.local/lib/a1577_produce.py" --ask="$WM_SUCC_ASK" --outdir "$_out" --inv="$_inv" 2>>"$LOG")"; then
    export WM_SUCC_INV="$(printf '%s\n' "$_env" | sed -n 's/^WM_SUCC_INV=//p')" WM_SUCC_BINDING="$(printf '%s\n' "$_env" | sed -n 's/^WM_SUCC_BINDING=//p')"
    echo "$(date +%FT%T%z) A1577 binding $WM_SUCC_BINDING for inv $WM_SUCC_INV" >> "$LOG"
  else echo "$(date +%FT%T%z) A1577 producer refused for $WM_SUCC_ASK: relaunch proceeds UNVERIFIED, no equivalence claimed" >> "$LOG"; unset WM_SUCC_INV WM_SUCC_BINDING; fi
else echo "$(date +%FT%T%z) A1577 wiring skipped (WM_SUCC_ASK unset or producer not installed): relaunch UNVERIFIED" >> "$LOG"
fi
exec "$(dirname "$(readlink -f "$0")")/ctl-relaunch.sh" "$fleet" "follow the fleet account switch (Joe 11-01 1:5x PM, approvals #207)"
