#!/usr/bin/env bash
# fable-launch.sh [--helper] <claude args incl. --model M --effort E>   (A1169, A1221; Joe 11-07 10:38 AM routing)
# Account is chosen by the ACTUAL selected model: Fable -> jyen.pm (effort default high; xhigh|max only with FABLE_LAUNCH_EFFORT_REASON); every other model -> josephsyen or jyen.tech
# by an atomic persistent round-robin (flock on $HOME/.cache/aide/account-rr/), new allocations only. A --resume SID is pinned to the
# account recorded for that SID at allocation. jyen.pm is never non-Fable; josephsyen/jyen.tech are never Fable; a missing credential
# for the chosen account exits 66 and never falls back to another account.
# Process-local only: exports CLAUDE_CODE_OAUTH_TOKEN for the exec'd claude. No rotation, no shared default edits, no token output.
# A Fable parent's native child agents inherit this env (jyen.pm); use `fable-launch.sh --helper --model sonnet ...` for separate-process helpers (round-robin account).
# A1300 managed skill route: `--route-request FILE` (JSON {task_id,skill,decision_class?,evidence_refs?,escalation?,review?}; task text is
# data, never interpolated) is resolved by skill-route-resolve.py against .config/skill-routing/policy.json. A denied or ungoverned
# route exits 64 before anything starts; an allowed route supplies --model/--effort (a conflicting --model/--effort is refused), a
# task-linked row is appended to ${SKILL_ROUTING_DECISIONS:-~/.local/state/skill-routing/decisions.jsonl}, and the worker env drops the
# ctl seat/model markers. Policy picks model+effort only; the account still follows the model exactly as below (policy cannot grant account or spend changes).
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
model=""; effort=""; sid=""; args=("$@"); out=(); i=0; ROUTE_REQ=""; SIDARG=0
while [ $i -lt ${#args[@]} ]; do
  a="${args[$i]}"
  case "$a" in
    --model) [ -z "$model" ] || { echo "fable-launch: duplicate --model refused" >&2; exit 64; }; model="${args[$((i+1))]:-}"; out+=("$a" "$model"); i=$((i+2)); continue ;;
    --model=*) [ -z "$model" ] || { echo "fable-launch: duplicate --model refused" >&2; exit 64; }; model="${a#--model=}"; out+=("$a") ;;
    --effort) [ -z "$effort" ] || { echo "fable-launch: duplicate --effort refused" >&2; exit 64; }; effort="${args[$((i+1))]:-}"; i=$((i+2)); continue ;;
    --effort=*) [ -z "$effort" ] || { echo "fable-launch: duplicate --effort refused" >&2; exit 64; }; effort="${a#--effort=}" ;;
    --route-request) ROUTE_REQ="${args[$((i+1))]:-}"; i=$((i+2)); continue ;;
    --route-request=*) ROUTE_REQ="${a#--route-request=}" ;;
    --session-id) SIDARG=1; sid="${args[$((i+1))]:-}"; out+=("$a" "$sid"); i=$((i+2)); continue ;;
    --session-id=*) SIDARG=1; sid="${a#--session-id=}"; out+=("$a") ;;
    --resume|-r) sid="${args[$((i+1))]:-}"; out+=("$a" "$sid"); i=$((i+2)); continue ;;
    --resume=*) sid="${a#--resume=}"; out+=("$a") ;;
    *) out+=("$a") ;;
  esac
  i=$((i+1))
done
ROUTED=0
DEC_LOG="${SKILL_ROUTING_DECISIONS:-$HOME/.local/state/skill-routing/decisions.jsonl}"
dec_row() { # decision, extra jq args...
  mkdir -p "$(dirname "$DEC_LOG")" 2>/dev/null
  jq -nc --arg ts "$(date -Is)" --arg d "$1" --arg tid "${R_TASK:-}" --arg sk "${R_SKILL:-}" --arg route "${R_ROUTE:-}" \
    --arg m "${model:-}" --arg e "${effort:-}" --arg acct "${ACCT:-}" --arg sid "${sid:-}" --arg why "${R_WHY:-}" --argjson resume "${R_RESUME:-false}" \
    '{ts:$ts,decision:$d,task_id:$tid,skill:$sk,route:$route,model:$m,effort:$e,account:$acct,session:$sid,resume:$resume,reasons:$why}' >>"$DEC_LOG" 2>/dev/null
}
if [ -n "$ROUTE_REQ" ]; then
  ROUTED=1
  HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
  RESOLVER="$HERE/../lib/skill-route-resolve.py"; [ -r "$RESOLVER" ] || RESOLVER="$HOME/.local/lib/skill-route-resolve.py"
  [ "${FABLE_LAUNCH_TEST:-0}" = 1 ] && [ -n "${SKILL_ROUTE_RESOLVER:-}" ] && RESOLVER="$SKILL_ROUTE_RESOLVER"
  [ -r "$ROUTE_REQ" ] && [ -r "$RESOLVER" ] || { echo "fable-launch: route request or resolver unreadable; refusing (fail closed)" >&2; exit 64; }
  RQ="$(mktemp)"; trap 'rm -f "$RQ"' EXIT
  jq -c --arg m "$model" --arg e "$effort" '.requested = ((.requested // {}) + (if $m!="" then {model:$m} else {} end) + (if $e!="" then {effort:$e} else {} end))' "$ROUTE_REQ" >"$RQ" 2>/dev/null \
    || { echo "fable-launch: route request is not valid JSON; refusing (fail closed)" >&2; exit 64; }
  R_TASK="$(jq -r '.task_id // ""' "$RQ" 2>/dev/null)"; R_SKILL="$(jq -r '.skill // ""' "$RQ" 2>/dev/null)"
  if ! RES="$(python3 -I "$RESOLVER" --file "$RQ")"; then
    R_WHY="$(printf '%s' "$RES" | jq -r '.error // "denied"' 2>/dev/null)"
    dec_row denied; echo "fable-launch: route DENIED, nothing started: $R_WHY" >&2
    echo "fable-launch: fix the request (task_id, decision_class, escalation{reason,evidence:[ledger:|file:|pr:|run:|commit:|page: refs]}) or use the baseline route; see .config/skill-routing/policy.json" >&2; exit 64
  fi
  [ "$(printf '%s' "$RES" | jq -r '.governed')" = true ] || { echo "fable-launch: skill '$R_SKILL' is not governed by skill routing; use a plain launch" >&2; exit 64; }
  model="$(printf '%s' "$RES" | jq -r '.model_id')"; effort="$(printf '%s' "$RES" | jq -r '.effort')"
  R_ROUTE="$(printf '%s' "$RES" | jq -r '.route')"; R_WHY="$(printf '%s' "$RES" | jq -r '.reasons|join("; ")')"
  rm -f "$RQ"; trap - EXIT
  nout=(); j=0; while [ $j -lt ${#out[@]} ]; do case "${out[$j]}" in --model) j=$((j+2)); continue ;; --model=*) ;; *) nout+=("${out[$j]}") ;; esac; j=$((j+1)); done
  out=("${nout[@]}" --model "$model")
fi
[ -n "$model" ] || { echo "fable-launch: --model is required (explicit model, no default)" >&2; exit 64; }
case "$model" in
  fable|claude-fable-[0-9]|claude-fable-[0-9]-[0-9]|claude-fable-[0-9]-[0-9]-[0-9]) IS_FABLE=1 ;;
  *fable*|*Fable*|*FABLE*) echo "fable-launch: unrecognized fable-like model '$model'" >&2; exit 64 ;;
  *) IS_FABLE=0 ;;
esac
if [ "$IS_FABLE" = 1 ]; then
  [ "$HELPER" = 0 ] || { echo "fable-launch: --helper must not be Fable" >&2; exit 64; }
  if [ "$ROUTED" = 0 ]; then
    # Fresh Fable default is high (A1300 fable-quota-routing addendum). xhigh/max are reasoned exceptions: a non-empty
    # FABLE_LAUNCH_EFFORT_REASON (>= 8 chars, e.g. "ledger:A1300 unresolved gap ...") is required and echoed; anything else is refused.
    EFFORT_REASON="${FABLE_LAUNCH_EFFORT_REASON:-}"; [ -n "$effort" ] || effort=high
    case "$effort" in
      high) ;;
      xhigh|max) [ "${#EFFORT_REASON}" -ge 8 ] || { echo "fable-launch: Fable $effort needs a recorded reason in FABLE_LAUNCH_EFFORT_REASON (default is high)" >&2; exit 64; }
                 echo "fable-launch: effort exception $effort: $EFFORT_REASON" >&2 ;;
      *) echo "fable-launch: unsupported Fable effort '$effort' (high; xhigh|max with a reason)" >&2; exit 64 ;;
    esac
  fi
  ACCT="$FABLE_ACCT"
  [[ "$ACCT" =~ ^[A-Za-z0-9._-]+$ ]] || exit 64
  [ -s "$STORE/$ACCT" ] || { echo "fable-launch: no stored credential for account '$ACCT'" >&2; exit 66; }
else
  ACCT=""   # non-Fable: allocated by alloc_nonfable_acct below (round-robin, resume pinned)
fi
alloc_nonfable_acct() {
  # Pin to the account recorded for this SID, else allocate the next pool account (counter under flock, advanced only when the chosen
  # account's credential exists, so a missing credential fails closed instead of skipping to the other account).
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
}
# Duplicate guard: do not resume a SID while another process for it is alive (detect only; kill by PID is the operator's call).
if [ -n "$sid" ] && [[ "$sid" =~ ^[0-9a-f-]{36}$ ]]; then
  dup="$(ps -eo pid=,ppid=,args= | awk -v s="$sid" -v me="$$" '$1!=me && $2!=me && index($0,s) && !/awk -v s=/ && !/fable-launch/ {print $1}' | head -3 | tr '\n' ' ')"
  [ -z "$dup" ] || { echo "fable-launch: session $sid already running (pid $dup); not resuming a duplicate" >&2; exit 73; }
fi
if [ "$ROUTED" = 1 ]; then
  # Same-session resume must keep the recorded route; a changed model/effort needs a new task session, not a silent switch.
  R_RESUME=false
  if [ -n "$sid" ] && [ "$SIDARG" = 0 ] && [ -r "$DEC_LOG" ]; then
    R_RESUME=true
    prev="$(jq -r --arg s "$sid" 'select(.session==$s and .decision=="launch")|"\(.model)/\(.effort)"' "$DEC_LOG" 2>/dev/null | tail -1)"
    [ -z "$prev" ] || [ "$prev" = "$model/$effort" ] || { R_WHY="resume route $model/$effort differs from session's recorded $prev"; dec_row denied; echo "fable-launch: $R_WHY; start a new session for the new route" >&2; exit 64; }
  fi
  # Duplicate dispatch: a live worker already launched for this task+skill blocks a second launch.
  if [ -r "$DEC_LOG" ]; then
    for psid in $(jq -r --arg t "$R_TASK" --arg k "$R_SKILL" 'select(.task_id==$t and .skill==$k and .decision=="launch" and .session!="")|.session' "$DEC_LOG" 2>/dev/null | sort -u); do
      [ "$psid" = "$sid" ] && continue
      if ps -eo args= | grep -F -- "$psid" | grep -vq grep; then R_WHY="task $R_TASK/$R_SKILL already has a live worker (session $psid)"; dec_row denied; echo "fable-launch: $R_WHY; not dispatching a duplicate" >&2; exit 73; fi
    done
  fi
  if [ -z "$sid" ]; then sid="$(cat /proc/sys/kernel/random/uuid)"; out+=(--session-id "$sid"); fi
  [ "$IS_FABLE" = 1 ] || alloc_nonfable_acct
  dec_row launch
  # Isolate the worker from the ctl seat: no ctl markers, no inherited model overrides.
  unset WM_SEAT ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL CLAUDE_CODE_SUBAGENT_MODEL
  export SKILL_ROUTE_TASK_ID="$R_TASK" SKILL_ROUTE_SKILL="$R_SKILL" SKILL_ROUTE_ROUTE="$R_ROUTE" SKILL_ROUTE_EFFORT="$effort"
fi
[ "$ROUTED" = 1 ] || [ "$IS_FABLE" = 1 ] || alloc_nonfable_acct
[[ "$ACCT" =~ ^[A-Za-z0-9._-]+$ ]] || exit 64
f="$STORE/$ACCT"
[ -s "$f" ] || { echo "fable-launch: no stored credential for account '$ACCT'" >&2; exit 66; }
tok="$(cat "$f")"
export CLAUDE_CODE_OAUTH_TOKEN="$tok"; unset tok
export FABLE_LAUNCH_ACCOUNT="$ACCT" FABLE_LAUNCH_MODEL="$model"
echo "fable-launch: account=$ACCT model=$model${effort:+ effort=$effort}" >&2
if [ -n "$effort" ]; then exec "$CLAUDE_BIN" "${out[@]}" --effort "$effort"; else exec "$CLAUDE_BIN" "${out[@]}"; fi
