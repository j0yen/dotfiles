#!/usr/bin/env bash
# aide-launch.sh — start the aide (Joe's interactive channel on carbon) with the FLEET token in its environment,
# so the aide session runs on the account the fleet runs on (Joe 10-23 10:5x AM "yes, start the aide with the fleet token").
#   aide-launch.sh [--account <store-name>] [claude args...]      e.g. aide-launch.sh --continue
#   default token = ~/.config/environment.d/90-claude-oauth.conf (what fleet-token-place.sh / rotate write)
#   --account NAME = that entry of ~/.config/fleet-token/store instead (runs the aide on a different account than the fleet)
# Never prints the token. /login inside the session still works and overrides for that session only.
set -u
ACCT=""
if [ "${1:-}" = "--account" ]; then ACCT="${2:?--account needs a store name}"; shift 2; fi
if [ -n "$ACCT" ]; then
  f="${XDG_CONFIG_HOME:-$HOME/.config}/fleet-token/store/$ACCT"
  [ -r "$f" ] || { echo "aide-launch: no store entry '$ACCT' (fleet-token-store.sh add $ACCT)" >&2; exit 64; }
  CLAUDE_CODE_OAUTH_TOKEN="$(tr -d '\n' < "$f")"; export CLAUDE_CODE_OAUTH_TOKEN
  echo "aide-launch: token from store/$ACCT" >&2
else
  set -a; . "$HOME/.config/environment.d/90-claude-oauth.conf"; set +a
  acct="$(jq -r '.account // "unknown"' "$HOME/.cache/fleet-dash/token.json" 2>/dev/null || echo unknown)"
  echo "aide-launch: fleet token (token.json says $acct, conf $(stat -c %y "$HOME/.config/environment.d/90-claude-oauth.conf" | cut -c1-16))" >&2
fi
[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || { echo "aide-launch: no token found" >&2; exit 1; }
cd "$HOME" || exit 70
# Model = the aide row of the seat-model hold (Joe 10-23 approvals #18), unless the caller passes --model.
# Without this a bare launch fell back to settings.local.json's default (Fable) — 10-23 12:02 PM aide opened on Fable.
case " $* " in *" --model "*|*" --model="*) ;; *)
  m="$(jq -r '.aide.model // empty' "$HOME/.config/wm-decide/seat-model-hold.json" 2>/dev/null)"
  [ -n "$m" ] && { set -- --model "$m" "$@"; echo "aide-launch: model $m (seat-model-hold aide row)" >&2; } ;;
esac
# agentns-claude is a compiled wrapper with an unverified argument contract: opt in with AIDE_USE_AGENTNS=1
# The ONLY place the aide identity is set (Joe 2026-10-23): hooks exempt/card/inbox/ledger key on WM_SEAT=aide; a plain `claude` on carbon is Joe's own session.
export WM_SEAT=aide
if [ "${AIDE_USE_AGENTNS:-0}" = 1 ] && command -v agentns-claude >/dev/null 2>&1; then exec agentns-claude --dangerously-skip-permissions "$@"; fi
exec ${AIDE_CLAUDE_BIN:-"$HOME/.npm-global/bin/claude"} --dangerously-skip-permissions "$@"
