#!/usr/bin/env bash
# fable-launch.sh [--helper] <claude args incl. --model M --effort E>   (A1169, A1221; Joe 11-07 10:38 AM routing)
# Account is chosen by the ACTUAL selected model: Fable -> jyen.pm (effort pinned xhigh); every other model -> josephsyen or jyen.tech
# by an atomic persistent round-robin (flock on $HOME/.cache/aide/account-rr/), new allocations only. A --resume SID is pinned to the
# account recorded for that SID at allocation. jyen.pm is never non-Fable; josephsyen/jyen.tech are never Fable; a missing credential
# for the chosen account exits 66 and never falls back to another account.
# Process-local only: exports CLAUDE_CODE_OAUTH_TOKEN for the exec'd claude. No rotation, no shared default edits, no token output.
# A Fable parent's native child agents inherit this env (jyen.pm); use `fable-launch.sh --helper --model sonnet ...` for separate-process helpers (round-robin account).
set -u
# Production pins the split: the account names, store and claude binary cannot be overridden from the environment.
# Overrides are honored only under FABLE_LAUNCH_TEST=1 (the test file sets it); anywhere else a set override is refused.
if [ "${FABLE_LAUNCH_TEST:-0}" = 1 ]; then
  STORE="${FABLE_TOKEN_STORE:-$HOME/.config/fleet-token/store}"; CLAUDE_BIN="${FABLE_CLAUDE_BIN:-$HOME/.npm-global/bin/claude}"
  FABLE_ACCT="${FABLE_ACCOUNT:-jyen.pm}"; RR_DIR="${FABLE_RR_DIR:-$HOME/.cache/aide/account-rr}"
else
  for _v in FABLE_ACCOUNT FABLE_BASE_ACCOUNT FABLE_TOKEN_STORE FABLE_CLAUDE_BIN FABLE_RR_DIR; do
    [ -z "${!_v:-}" ] || { echo "fable-launch: $_v override refused (account split is fixed)" >&2; exit 64; }
  done
  STORE="$HOME/.config/fleet-token/store"; CLAUDE_BIN="$HOME/.npm-global/bin/claude"; FABLE_ACCT=jyen.pm; RR_DIR="$HOME/.cache/aide/account-rr"
fi
RR_ACCTS=(josephsyen jyen.tech)   # exact non-Fable pool; jyen.pm is Fable only
HELPER=0; [ "${1:-}" = --helper ] && { HELPER=1; shift; }
model=""; effort=""; sid=""; args=("$@"); out=(); i=0
while [ $i -lt ${#args[@]} ]; do
  a="${args[$i]}"
  case "$a" in
    --model) [ -z "$model" ] || { echo "fable-launch: duplicate --model refused" >&2; exit 64; }; model="${args[$((i+1))]:-}"; out+=("$a" "$model"); i=$((i+2)); continue ;;
    --model=*) [ -z "$model" ] || { echo "fable-launch: duplicate --model refused" >&2; exit 64; }; model="${a#--model=}"; out+=("$a") ;;
    --effort) [ -z "$effort" ] || { echo "fable-launch: duplicate --effort refused" >&2; exit 64; }; effort="${args[$((i+1))]:-}"; i=$((i+2)); continue ;;
    --effort=*) [ -z "$effort" ] || { echo "fable-launch: duplicate --effort refused" >&2; exit 64; }; effort="${a#--effort=}" ;;
    --session-id) sid="${args[$((i+1))]:-}"; out+=("$a" "$sid"); i=$((i+2)); continue ;;
    --session-id=*) sid="${a#--session-id=}"; out+=("$a") ;;
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
fi
# Duplicate guard: do not resume a SID while another process for it is alive (detect only; kill by PID is the operator's call).
if [ -n "$sid" ] && [[ "$sid" =~ ^[0-9a-f-]{36}$ ]]; then
  dup="$(ps -eo pid=,ppid=,args= | awk -v s="$sid" -v me="$$" '$1!=me && $2!=me && index($0,s) && !/awk -v s=/ && !/fable-launch/ {print $1}' | head -3 | tr '\n' ' ')"
  [ -z "$dup" ] || { echo "fable-launch: session $sid already running (pid $dup); not resuming a duplicate" >&2; exit 73; }
fi
if [ "$IS_FABLE" = 0 ]; then
  # Non-Fable: pin to the account recorded for this SID, else allocate the next pool account (counter under flock, advanced only
  # when the chosen account's credential exists, so a missing credential fails closed instead of skipping to the other account).
  [ -z "$sid" ] || [[ "$sid" =~ ^[0-9a-f-]{36}$ ]] || { echo "fable-launch: malformed session id" >&2; exit 64; }
  mkdir -p "$RR_DIR" || { echo "fable-launch: cannot create $RR_DIR" >&2; exit 70; }
  exec 9>"$RR_DIR/lock" || exit 70
  flock -x 9 || exit 70
  ACCT=""
  [ -z "$sid" ] || ACCT="$(awk -v s="$sid" '$1==s {a=$2} END{print a}' "$RR_DIR/sid-map" 2>/dev/null)"
  if [ -n "$ACCT" ]; then
    case " ${RR_ACCTS[*]} " in *" $ACCT "*) ;; *) echo "fable-launch: session $sid is pinned to '$ACCT', not a non-Fable pool account" >&2; exit 65 ;; esac
    [ -s "$STORE/$ACCT" ] || { echo "fable-launch: no stored credential for pinned account '$ACCT' (session $sid not moved to another account)" >&2; exit 66; }
  else
    n="$(cat "$RR_DIR/counter" 2>/dev/null)"; [[ "$n" =~ ^[0-9]+$ ]] || n=0
    ACCT="${RR_ACCTS[$((n % ${#RR_ACCTS[@]}))]}"
    [ -s "$STORE/$ACCT" ] || { echo "fable-launch: no stored credential for account '$ACCT' (round-robin slot $n; no fallback to another account)" >&2; exit 66; }
    printf '%s' "$((n+1))" > "$RR_DIR/counter.tmp" && mv -f "$RR_DIR/counter.tmp" "$RR_DIR/counter" || exit 70
    [ -z "$sid" ] || printf '%s %s\n' "$sid" "$ACCT" >> "$RR_DIR/sid-map"
  fi
  exec 9>&-
fi
[[ "$ACCT" =~ ^[A-Za-z0-9._-]+$ ]] || exit 64
f="$STORE/$ACCT"
[ -s "$f" ] || { echo "fable-launch: no stored credential for account '$ACCT'" >&2; exit 66; }
tok="$(cat "$f")"
export CLAUDE_CODE_OAUTH_TOKEN="$tok"; unset tok
export FABLE_LAUNCH_ACCOUNT="$ACCT" FABLE_LAUNCH_MODEL="$model"
echo "fable-launch: account=$ACCT model=$model${effort:+ effort=$effort}" >&2
if [ -n "$effort" ]; then exec "$CLAUDE_BIN" "${out[@]}" --effort "$effort"; else exec "$CLAUDE_BIN" "${out[@]}"; fi
