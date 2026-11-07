#!/usr/bin/env bash
# fable-launch.sh [--helper] <claude args incl. --model M --effort E>   (A1169, Joe 11-07 early switch)
# Account is chosen by the ACTUAL selected model: Fable -> jyen.pm (effort pinned xhigh); every other model -> josephsyen, explicit.
# Process-local only: exports CLAUDE_CODE_OAUTH_TOKEN for the exec'd claude. No rotation, no shared default edits, no token output.
# A Fable parent's native child agents inherit this env (jyen.pm); use `fable-launch.sh --helper --model sonnet ...` for separate-process helpers on josephsyen.
set -u
STORE="${FABLE_TOKEN_STORE:-$HOME/.config/fleet-token/store}"
CLAUDE_BIN="${FABLE_CLAUDE_BIN:-$HOME/.npm-global/bin/claude}"
FABLE_ACCT="${FABLE_ACCOUNT:-jyen.pm}"; BASE_ACCT="${FABLE_BASE_ACCOUNT:-josephsyen}"
HELPER=0; [ "${1:-}" = --helper ] && { HELPER=1; shift; }
model=""; effort=""; sid=""; args=("$@"); out=(); i=0
while [ $i -lt ${#args[@]} ]; do
  a="${args[$i]}"
  case "$a" in
    --model) model="${args[$((i+1))]:-}"; out+=("$a" "$model"); i=$((i+2)); continue ;;
    --model=*) model="${a#--model=}"; out+=("$a") ;;
    --effort) effort="${args[$((i+1))]:-}"; i=$((i+2)); continue ;;
    --effort=*) effort="${a#--effort=}" ;;
    --resume|-r) sid="${args[$((i+1))]:-}"; out+=("$a" "$sid"); i=$((i+2)); continue ;;
    --resume=*) sid="${a#--resume=}"; out+=("$a") ;;
    *) out+=("$a") ;;
  esac
  i=$((i+1))
done
[ -n "$model" ] || { echo "fable-launch: --model is required (explicit model, no default)" >&2; exit 64; }
case "$model" in
  fable|claude-fable-[0-9]|claude-fable-[0-9]-[0-9]|claude-fable-[0-9]-[0-9]-[0-9]) IS_FABLE=1 ;;
  *fable*|*Fable*|*FABLE*) echo "fable-launch: unrecognized fable-like model '$model'" >&2; exit 64 ;;
  *) IS_FABLE=0 ;;
esac
if [ "$IS_FABLE" = 1 ]; then
  [ "$HELPER" = 0 ] || { echo "fable-launch: --helper must not be Fable" >&2; exit 64; }
  [ -z "$effort" ] || [ "$effort" = xhigh ] || { echo "fable-launch: Fable runs xhigh only (got '$effort')" >&2; exit 64; }
  effort=xhigh; ACCT="$FABLE_ACCT"
else
  ACCT="$BASE_ACCT"
fi
[[ "$ACCT" =~ ^[A-Za-z0-9._-]+$ ]] || exit 64
f="$STORE/$ACCT"
[ -s "$f" ] || { echo "fable-launch: no stored credential for account '$ACCT'" >&2; exit 66; }
# Duplicate guard: do not resume a SID while another process for it is alive (detect only; kill by PID is the operator's call).
if [ -n "$sid" ] && [[ "$sid" =~ ^[0-9a-f-]{36}$ ]]; then
  dup="$(ps -eo pid=,ppid=,args= | awk -v s="$sid" -v me="$$" '$1!=me && $2!=me && index($0,s) && !/awk -v s=/ {print $1}' | head -3 | tr '\n' ' ')"
  [ -z "$dup" ] || { echo "fable-launch: session $sid already running (pid $dup); not resuming a duplicate" >&2; exit 73; }
fi
tok="$(cat "$f")"
export CLAUDE_CODE_OAUTH_TOKEN="$tok"; unset tok
export FABLE_LAUNCH_ACCOUNT="$ACCT"
echo "fable-launch: account=$ACCT model=$model${effort:+ effort=$effort}" >&2
if [ -n "$effort" ]; then exec "$CLAUDE_BIN" "${out[@]}" --effort "$effort"; else exec "$CLAUDE_BIN" "${out[@]}"; fi
