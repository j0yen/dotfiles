#!/usr/bin/env bash
# grader-jyenpm-run.sh <wm-decide args...>  (A1221, f8fe; A1300 routing 11-10; A388 no-Fable release 11-19): the regrader (wm-decide regrade,
# grader model budget.MODEL = claude-opus-5-5) runs on the NON-Fable lane account the account-lane policy selects: the nonfable primaries in
# the installed round-robin, skipping exhausted ones, the reserve only when every primary is exhausted. A paid/overage prompt is never a
# fallback (account-lane classify). No Fable lane, no Fable model: an argument naming Fable is refused before any account read.
# Was a carbon-only file selecting `--lane fable` (sha256 7384f63b...); the name is kept for the unit drop-in 99z-grader-release-f8fe.conf.
# Builds a mode-600 token file from the fleet-token store for this process only (never printed), points WM_DECIDE_TOKEN_FILE at it, runs
# wm-decide, removes the file on exit. GJ_ACCOUNT=<acct> pins an account only when `account-lane check --lane nonfable` permits it now.
# Exit: 64 Fable argument, 66 no credential for the account, 75 lane exhausted / policy unreadable, 77 GJ_ACCOUNT refused; else wm-decide's rc.
# Test knobs (tests only): GJ_STORE, GJ_WMD, GJ_LANE_TOOL.
set -u
. "$HOME/.local/lib/fleet-token-lib.sh"; ft_paths
STORE="${GJ_STORE:-$FT_STORE}"
WMD="${GJ_WMD:-$HOME/.local/share/swarm-decide/live/current/bin/wm-decide}"
AL="${GJ_LANE_TOOL:-$HOME/.local/lib/account-lane.py}"
for arg in "$@"; do
  case "${arg,,}" in *fable*) echo "grader-jyenpm-run: refusing Fable argument '$arg': no Fable anywhere (Joe 2026-11-18)" >&2; exit 64;; esac
done
if [ -n "${GJ_ACCOUNT:-}" ]; then
  acct="$(python3 -I "$AL" check --lane nonfable --account "$GJ_ACCOUNT" 2>/dev/null | jq -r 'select(.ok==true) | .account' 2>/dev/null)"
  [ -n "$acct" ] || { echo "grader-jyenpm-run: GJ_ACCOUNT=$GJ_ACCOUNT is not permitted or is exhausted in the nonfable lane; refusing" >&2; exit 77; }
else
  acct="$(python3 -I "$AL" select --lane nonfable 2>/dev/null | jq -r 'select(.ok==true) | .account' 2>/dev/null)"
  [ -n "$acct" ] || { echo "grader-jyenpm-run: account lane policy selects no non-Fable account (lane exhausted or policy unreadable); refusing" >&2; exit 75; }
fi
tok="$(ft_token_of "$STORE/$acct" 2>/dev/null)"
[ -n "$tok" ] || { echo "grader-jyenpm-run: no $acct credential in the store; refusing" >&2; exit 66; }
echo "grader-jyenpm-run: non-Fable lane account $acct" >&2
tf="$(mktemp "${XDG_RUNTIME_DIR:-/tmp}/gj.XXXXXX")"; chmod 600 "$tf"
trap 'rm -f "$tf"' EXIT
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$tok" > "$tf"; unset tok
WM_DECIDE_TOKEN_FILE="$tf" "$WMD" "$@"
