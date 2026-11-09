#!/usr/bin/env bash
# ctl-launch.sh — start the carbon ctl seat (aide merged into ctl, Joe 11-06 #244; hermes-handover item 2.1) with the FLEET token
# in its environment, so the seat runs on the account the fleet runs on (Joe 10-23 10:5x AM "yes, start the aide with the fleet token").
# Compat: aide-launch.sh is a shim that execs this script; AIDE_* env names, ~/.cache/aide/pane and tmux session `aide` are unchanged.
#   ctl-launch.sh [--account <store-name>] [--lane <name>] [claude args...]      e.g. ctl-launch.sh --continue
#   --lane <name> (aide-lanes 10-27; default main = today's launch path byte-for-byte): exports WM_AIDE_LANE for the hooks (own inbox/cursor,
#     seat-event.sh aide:<name>, claim gate, lane handoff file), refuses (65) until the deployed aide-inbox.sh carries the lane branch,
#     adds --disallowedTools ScheduleWakeup, and makes the carbon ROOM check (exit 75) before the spawn.
#   default token = ~/.config/environment.d/90-claude-oauth.conf (what fleet-token-place.sh / rotate write)
#   --account NAME = that entry of ~/.config/fleet-token/store instead (runs the aide on a different account than the fleet)
# Never prints the token. /login inside the session still works and overrides for that session only.
set -u
ACCT=""; LANE=main
while :; do   # --account and --lane, either order, before the claude args
  case "${1:-}" in
    --account) ACCT="${2:?--account needs a store name}"; shift 2 ;;
    --lane) LANE="${2:?--lane needs a name}"; shift 2 ;;
    *) break ;;
  esac
done
# Reject wrong models/efforts before credentials, tmux or a provider are touched.
for _pl in "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/ctl-model-policy.sh" "$HOME/.local/lib/ctl-model-policy.sh"; do [ -r "$_pl" ] && break; done
. "$_pl" || exit 64
ctl_model_policy "$@" || exit $?
set -- "${CTL_POLICY_ARGS[@]}"
_self="$(readlink -f "${BASH_SOURCE[0]}")"
for _l in "${AIDE_LANE_LIB:-}" "$(dirname "$_self")/../lib/aide-lane.sh" "$HOME/.local/lib/aide-lane.sh"; do [ -n "$_l" ] && [ -r "$_l" ] && { . "$_l"; break; }; done
type aide_lane_valid >/dev/null 2>&1 || { echo "ctl-launch: aide-lane.sh lib not found (AIDE_LANE_LIB, ../lib, ~/.local/lib)" >&2; exit 1; }
aide_lane_valid "$LANE" || { echo "ctl-launch: bad lane name '$LANE' ($AIDE_LANE_RE)" >&2; exit 64; }
if [ -n "$ACCT" ]; then
  f="${XDG_CONFIG_HOME:-$HOME/.config}/fleet-token/store/$ACCT"
  [ -r "$f" ] || { echo "ctl-launch: no store entry '$ACCT' (fleet-token-store.sh add $ACCT)" >&2; exit 64; }
  CLAUDE_CODE_OAUTH_TOKEN="$(tr -d '\n' < "$f")"; export CLAUDE_CODE_OAUTH_TOKEN
  echo "ctl-launch: token from store/$ACCT" >&2
else
  set -a; . "$HOME/.config/environment.d/90-claude-oauth.conf"; set +a
  acct="$(jq -r '.account // "unknown"' "$HOME/.cache/fleet-dash/token.json" 2>/dev/null || echo unknown)"
  echo "ctl-launch: fleet token (token.json says $acct, conf $(stat -c %y "$HOME/.config/environment.d/90-claude-oauth.conf" | cut -c1-16))" >&2
fi
[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || { echo "ctl-launch: no token found" >&2; exit 1; }
cd "$HOME" || exit 70
# Model and effort were validated and explicitly pinned before authentication.
# agentns-claude is a compiled wrapper with an unverified argument contract: opt in with AIDE_USE_AGENTNS=1
# The ONLY place the carbon executor identity is set (Joe 2026-10-23; renamed ctl 2026-11-06): hooks exempt/card/inbox/ledger key on WM_SEAT=ctl (WM_SEAT=aide still accepted); a plain `claude` on carbon is Joe's own session.
export WM_SEAT=ctl
export WM_AIDE_LANE="$LANE"
if [ "$LANE" != main ]; then
  hook="${AIDE_INBOX_HOOK:-$HOME/.claude/hooks/aide-inbox.sh}"
  grep -q WM_AIDE_LANE "$hook" 2>/dev/null || { echo "ctl-launch: lane $LANE needs the lane branch deployed (grep WM_AIDE_LANE ~/.claude/hooks/aide-inbox.sh)" >&2; exit 65; }
  # ROOM check (carbon is 14 G, the seats need >= 3 G): MemAvailable minus one more aide's peak must keep the floor. Never runs for main.
  # AIDE_LANE_PEAK_MB_DEFAULT = the main aide's VmHWM (/proc/<pid>/status, 1941756 kB on 2026-10-27) rounded up to the next 512 MB.
  if [ "${AIDE_LANE_SKIP_ROOM:-0}" != 1 ]; then
    AIDE_LANE_PEAK_MB_DEFAULT=2048
    peak="${AIDE_LANE_PEAK_MB:-$AIDE_LANE_PEAK_MB_DEFAULT}"; [[ "$peak" =~ ^[0-9]{1,7}$ ]] || peak=$AIDE_LANE_PEAK_MB_DEFAULT
    avail_mb=$(( $(awk '/^MemAvailable:/{print $2}' "${AIDE_LANE_MEMINFO:-/proc/meminfo}" 2>/dev/null | head -n1 | grep -E '^[0-9]+$' || echo 0) / 1024 ))
    if [ $((avail_mb - peak)) -lt 3072 ]; then
      echo "ctl-launch: no room for lane $LANE: MemAvailable $avail_mb MB - peak $peak MB < 3072 MB floor" >&2; exit 75
    fi
  fi
  set -- --disallowedTools ScheduleWakeup "$@"
fi
# Pre-accept the folder-trust dialog for $HOME (11-01 1:31 AM rehearsal relaunch sat at "No, exit" unattended, A292):
# --dangerously-skip-permissions does not skip it, and an unattended relaunch has nobody to press a key.
cj="${AIDE_CLAUDE_JSON:-$HOME/.claude.json}"
if [ -f "$cj" ] && [ "$(jq -r --arg d "$HOME" '.projects[$d].hasTrustDialogAccepted // false' "$cj" 2>/dev/null)" != true ]; then
  t="$(mktemp "$cj.aide.XXXXXX")" && jq --arg d "$HOME" '.projects[$d].hasTrustDialogAccepted = true' "$cj" > "$t" && [ -s "$t" ] && mv -f "$t" "$cj" \
    && echo "ctl-launch: trust pre-accepted for $HOME" >&2 || { rm -f "$t"; echo "ctl-launch: WARN trust pre-accept failed ($cj)" >&2; }
fi
# A7 aide-wake: a tmux pane is the only external wake path (aide-wake.sh check pokes it). Inside tmux the pane is recorded; AIDE_TMUX=1 outside tmux
# re-runs this script in a detached tmux session `aide` (attach: tmux attach -t aide). Default (unset) = unchanged launch.
wd="${AIDE_WAKE_DIR:-$HOME/.cache/aide}"
if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
  mkdir -p "$wd" && printf '%s\n' "$TMUX_PANE" > "$wd/pane"
elif [ "${AIDE_TMUX:-0}" = 1 ] && command -v "${AIDE_TMUX_BIN:-tmux}" >/dev/null 2>&1; then
  exec "${AIDE_TMUX_BIN:-tmux}" new-session -s aide "$(readlink -f "$0")" "$@"
fi
if [ "${AIDE_USE_AGENTNS:-0}" = 1 ] && command -v agentns-claude >/dev/null 2>&1; then exec agentns-claude --dangerously-skip-permissions "$@"; fi
exec ${AIDE_CLAUDE_BIN:-"$HOME/.npm-global/bin/claude"} --dangerously-skip-permissions "$@"
