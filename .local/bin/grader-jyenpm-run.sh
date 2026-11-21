#!/usr/bin/env bash
# grader-jyenpm-run.sh <wm-decide args...>  (A1221, f8fe; A1300 routing 11-10; A388 no-Fable release 11-19): the regrader (wm-decide regrade,
# grader model budget.MODEL = claude-opus-5-5) runs on the NON-Fable lane account the account-lane policy selects: the nonfable primaries in
# the installed round-robin, skipping exhausted ones, the reserve only when every primary is exhausted. A paid/overage prompt is never a
# fallback (account-lane classify). No Fable lane, no Fable model: an argument naming Fable is refused before any account read.
# Was a carbon-only file selecting `--lane fable` (sha256 7384f63b...); the name is kept for the unit drop-in 99z-grader-release-f8fe.conf.
# Builds a mode-600 token file from the fleet-token store for this process only (never printed), points WM_DECIDE_TOKEN_FILE at it, runs
# wm-decide, removes the file on exit. GJ_ACCOUNT=<acct> pins an account only when `account-lane check --lane nonfable` permits it now.
# Round 3 (review 11c89fff F2; Hermes 2026-11-20): the wrapper owns the grader binding. Before any account read it preflights the exact engine it is
# about to run: `wm-decide regrade --binding` must print exactly the pinned binding (model claude-opus-5-5, effort high, refuses_fable, drain,
# model_usage_equality, binding 1), and `wm-decide regrade --model claude-fable-5-1 --dry-run` must be refused (rc 2, "refuses Fable model")
# with no model call. An engine without that contract (live-gs-931bed9, a partial install, a rollback) fails closed with 78. The real run gets
# the explicit `--model claude-opus-5-5`. A caller --model or --max-batches (an overall batch ceiling; use --drain) is refused.
# Review b0e9b031 F4: only the exact invocation `regrade [--backlog] [--include-tooling] [--limit N] --drain` passes (argparse prefixes refused).
# Exit: 64 Fable argument / caller --model / --max-batches / not the approved invocation, 66 no credential for the account, 75 lane exhausted / policy unreadable,
# 77 GJ_ACCOUNT refused, 78 engine is not the pinned grader binding; else wm-decide's rc.
# Test knobs (tests only): GJ_STORE, GJ_WMD, GJ_LANE_TOOL.
set -u
. "$HOME/.local/lib/fleet-token-lib.sh"; ft_paths
STORE="${GJ_STORE:-$FT_STORE}"
WMD="${GJ_WMD:-$HOME/.local/share/swarm-decide/live/current/bin/wm-decide}"
AL="${GJ_LANE_TOOL:-$HOME/.local/lib/account-lane.py}"
GRADER_MODEL=claude-opus-5-5
GRADER_BINDING='{"binding":1,"drain":true,"effort":"high","model":"claude-opus-5-5","model_usage_equality":true,"refuses_fable":true}'
for arg in "$@"; do
  case "${arg,,}" in *fable*) echo "grader-jyenpm-run: refusing Fable argument '$arg': no Fable anywhere (Joe 2026-11-18)" >&2; exit 64;; esac
  case "$arg" in
    --max-batches|--max-batches=*) echo "grader-jyenpm-run: refusing $arg: an overall batch ceiling is not approved (Hermes 2026-11-20); use --drain" >&2; exit 64;;
    --model|--model=*) echo "grader-jyenpm-run: refusing caller $arg: the wrapper binds the grader model ($GRADER_MODEL)" >&2; exit 64;;
  esac
done
# exact allow-list (review b0e9b031 F4/N3): the engine's argparse takes unambiguous prefixes (--max -> --max-batches, --mo -> --model), so only the
# exact approved grader invocation passes, before any engine run or account read: `regrade` first, then only --backlog, --include-tooling,
# --limit N (N = 1-9 then digits; the engine checks its range) and --drain, which is required. Anything else is refused with 64.
gj_refuse() {
  echo "grader-jyenpm-run: refusing $1: the approved grader invocation is 'regrade [--backlog] [--include-tooling] [--limit N] --drain'" \
       "(no overall batch ceiling, no caller --model, no other option or subcommand)" >&2; exit 64
}
[ "${1:-}" = regrade ] || gj_refuse "subcommand '${1:-}'"
gj_drain=0; i=2
while [ "$i" -le "$#" ]; do
  a="${!i}"
  case "$a" in
    --backlog|--include-tooling) ;;
    --drain) gj_drain=1 ;;
    --limit) i=$((i + 1)); v="${!i:-}"; [[ "$v" =~ ^[1-9][0-9]*$ ]] || gj_refuse "--limit '$v'" ;;
    --limit=*) [[ "${a#--limit=}" =~ ^[1-9][0-9]*$ ]] || gj_refuse "'$a'" ;;
    *) gj_refuse "'$a'" ;;
  esac
  i=$((i + 1))
done
[ "$gj_drain" = 1 ] || gj_refuse "a call without --drain"
# engine preflight (F2): the binding the engine reports, then its actual Fable refusal; no token in the environment, no account read yet
got="$(env -u WM_DECIDE_TOKEN_FILE "$WMD" regrade --binding 2>/dev/null)"; brc=$?
norm="$(printf '%s' "$got" | jq -cS . 2>/dev/null)"
if [ "$brc" != 0 ] || [ "$norm" != "$(printf '%s' "$GRADER_BINDING" | jq -cS .)" ]; then
  echo "grader-jyenpm-run: $WMD is not the pinned grader binding (regrade --binding rc=$brc: ${got:0:200}); refusing, no model call" >&2; exit 78
fi
probe="$(env -u WM_DECIDE_TOKEN_FILE "$WMD" regrade --model claude-fable-5-1 --dry-run 2>&1 >/dev/null)"; prc=$?
if [ "$prc" != 2 ] || [[ "$probe" != *"refuses Fable model"* ]]; then
  echo "grader-jyenpm-run: $WMD did not refuse a Fable model (rc=$prc: ${probe:0:200}); refusing, no model call" >&2; exit 78
fi
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
WM_DECIDE_TOKEN_FILE="$tf" "$WMD" "$@" --model "$GRADER_MODEL"
