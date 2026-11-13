#!/usr/bin/env bash
# fable-launch.sh [--helper] <claude args incl. --model M --effort E>   (A1169, A1221; Joe 11-07 10:38 AM routing)
# Account is chosen by the ACTUAL selected model AND durable per-lane exhaustion state (.local/lib/account-lane.py, A1300/A1301):
#   Fable -> mcphost.dev until its Fable lane is exhausted, then jyen.pm; other models -> the policy's nonfable primaries (jyen.pm) by the persistent round-robin (A1221, counter in the lane state under the same lock; exhausted primaries skipped; a missing credential gives the slot back and never rotates), mcphost.dev reserve only when ALL primaries are exhausted (.config/account-lanes/policy.json).
#   Reserve use is lane-state driven: no usage-percent or calendar input. Fable effort default high; xhigh|max only with FABLE_LAUNCH_EFFORT_REASON. No selectable account = structured block, exit 75 (no paid/API fallback).
#   Exit: 75 lane blocked/transfer unsupported, 76 state or policy invalid, 77 unknown-effect resume needs FABLE_LAUNCH_ACK_UNKNOWN_EFFECT, 73 duplicate live session.
#   Headless (-p/--print) launches run supervised so a usage-limit failure is classified and recorded; interactive launches still exec.
# Process-local only: exports CLAUDE_CODE_OAUTH_TOKEN for the exec'd claude. No rotation, no shared default edits, no token output.
# A Fable parent's native child agents inherit this env (mcphost.dev); use `fable-launch.sh --helper --model sonnet ...` for separate-process helpers on the nonfable lane.
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
  FABLE_ACCT="${FABLE_ACCOUNT:-jyen.pm}"; BASE_ACCT="${FABLE_BASE_ACCOUNT:-josephsyen}"; RR_DIR="${FABLE_RR_DIR:-$HOME/.cache/aide/account-rr}"
  [ -n "${ACCOUNT_LANE_STATE:-}" ] || { echo "fable-launch: test mode needs ACCOUNT_LANE_STATE (never the real state dir)" >&2; exit 64; }
  LANE_PY="${ACCOUNT_LANE_PY:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/account-lane.py}"
else
  for _v in FABLE_ACCOUNT FABLE_BASE_ACCOUNT FABLE_TOKEN_STORE FABLE_CLAUDE_BIN FABLE_RR_DIR; do
    [ -z "${!_v:-}" ] || { echo "fable-launch: $_v override refused (account split is fixed)" >&2; exit 64; }
  done
  for _v in ACCOUNT_LANE_STATE ACCOUNT_LANE_POLICY ACCOUNT_LANE_PY ACCOUNT_LANE_TEST ACCOUNT_LANE_NOW; do
    [ -z "${!_v:-}" ] || { echo "fable-launch: $_v override refused (lane state/policy are fixed)" >&2; exit 64; }
  done
  STORE="$HOME/.config/fleet-token/store"; CLAUDE_BIN="$HOME/.npm-global/bin/claude"; FABLE_ACCT=jyen.pm; BASE_ACCT=josephsyen; RR_DIR="$HOME/.cache/aide/account-rr"
  LANE_PY="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/account-lane.py"; [ -r "$LANE_PY" ] || LANE_PY="$HOME/.local/lib/account-lane.py"
fi
HELPER=0; [ "${1:-}" = --helper ] && { HELPER=1; shift; }
model=""; effort=""; sid=""; RESUME=0; HEADLESS=0; NOPERSIST=0; OFSEEN=0; OUTFMT=text; args=("$@"); out=(); tail=(); i=0; ROUTE_REQ=""; SIDARG=0
while [ $i -lt ${#args[@]} ]; do
  a="${args[$i]}"
  case "$a" in
    # The caller's first bare `--` ends launcher parsing: it and everything after it is the caller's opaque payload (prompt words, further
    # separators, option-looking tokens), kept byte-exact in $tail and appended LAST, so every option the launcher injects precedes it.
    --) tail=("${args[@]:$i}"); break ;;
    --model) [ -z "$model" ] || { echo "fable-launch: duplicate --model refused" >&2; exit 64; }; model="${args[$((i+1))]:-}"; out+=("$a" "$model"); i=$((i+2)); continue ;;
    --model=*) [ -z "$model" ] || { echo "fable-launch: duplicate --model refused" >&2; exit 64; }; model="${a#--model=}"; out+=("$a") ;;
    --effort) [ -z "$effort" ] || { echo "fable-launch: duplicate --effort refused" >&2; exit 64; }; effort="${args[$((i+1))]:-}"; i=$((i+2)); continue ;;
    --effort=*) [ -z "$effort" ] || { echo "fable-launch: duplicate --effort refused" >&2; exit 64; }; effort="${a#--effort=}" ;;
    --route-request) ROUTE_REQ="${args[$((i+1))]:-}"; i=$((i+2)); continue ;;
    --route-request=*) ROUTE_REQ="${a#--route-request=}" ;;
    --session-id=*) SIDARG=1; sid="${a#--session-id=}"; out+=("$a") ;;
    --session-id) SIDARG=1; sid="${args[$((i+1))]:-}"; out+=("$a" "$sid"); i=$((i+2)); continue ;;
    --resume|-r) sid="${args[$((i+1))]:-}"; RESUME=1; out+=("$a" "$sid"); i=$((i+2)); continue ;;
    --resume=*) sid="${a#--resume=}"; RESUME=1; out+=("$a") ;;
    --continue|-c) echo "fable-launch: --continue cannot be mapped to a session/account; use --resume <session-id> (A1300)" >&2; exit 64 ;;
    -p|--print) HEADLESS=1; out+=("$a") ;;
    --no-session-persistence) NOPERSIST=1; out+=("$a") ;;
    --output-format) [ "$OFSEEN" = 0 ] || { echo "fable-launch: duplicate --output-format refused" >&2; exit 64; }; OFSEEN=1; OUTFMT="${args[$((i+1))]:-}"; out+=("$a" "$OUTFMT"); i=$((i+2)); continue ;;
    --output-format=*) [ "$OFSEEN" = 0 ] || { echo "fable-launch: duplicate --output-format refused" >&2; exit 64; }; OFSEEN=1; OUTFMT="${a#--output-format=}"; out+=("$a") ;;
    *) out+=("$a") ;;
  esac
  i=$((i+1))
done
# The CLI's own --output-format decides how the supervisor reads headless output; stdout content never does. Unknown/empty value = refuse.
case "$OUTFMT" in text|json|stream-json) ;; *) echo "fable-launch: unsupported --output-format '$OUTFMT' (text|json|stream-json)" >&2; exit 64 ;; esac
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
fi
LANE=nonfable; [ "$IS_FABLE" = 1 ] && LANE=fable
[ -r "$LANE_PY" ] || { echo "fable-launch: account-lane.py missing; refusing (fail closed, no default account)" >&2; exit 76; }
ACCT=""   # the account is chosen ATOMICALLY with the session claim below (select + claim under one lock); nothing is read before that
# Duplicate guard: do not resume a SID while another process for it is alive (detect only; kill by PID is the operator's call).
if [ -n "$sid" ] && [[ "$sid" =~ ^[0-9a-f-]{36}$ ]]; then
  # Our own ancestors (a `sh -c "... --session-id <sid>"` wrapper from tmux/systemd/ssh) legitimately carry the id and are not duplicates;
  # the atomic pid+starttime claim below is the real duplicate guard.
  anc=" "; _p=$$; for _i in 1 2 3 4 5 6 7 8; do anc="$anc$_p "; _p="$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d ' ')"; [[ "$_p" =~ ^[0-9]+$ ]] && [ "$_p" -gt 1 ] || break; done
  dup="$(ps -eo pid=,ppid=,args= | awk -v s="$sid" -v me="$$" -v anc="$anc" '$1!=me && $2!=me && index(anc, " " $1 " ")==0 && index($0,s) && !/awk -v s=/ {print $1}' | head -3 | tr '\n' ' ')"
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
      if ps -eo comm=,args= | awk -v s="$psid" '$1 ~ /^(claude|node)$/ && index($0, s) { f = 1 } END { exit !f }'; then R_WHY="task $R_TASK/$R_SKILL already has a live worker (session $psid)"; dec_row denied; echo "fable-launch: $R_WHY; not dispatching a duplicate" >&2; exit 73; fi
    done
  fi
  if [ -z "$sid" ]; then sid="$(cat /proc/sys/kernel/random/uuid)"; out+=(--session-id "$sid"); fi
  # Isolate the worker from the ctl seat: no ctl markers, no inherited model overrides.
  unset WM_SEAT ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL CLAUDE_CODE_SUBAGENT_MODEL
  export SKILL_ROUTE_TASK_ID="$R_TASK" SKILL_ROUTE_SKILL="$R_SKILL" SKILL_ROUTE_ROUTE="$R_ROUTE" SKILL_ROUTE_EFFORT="$effort"
fi
# Every launch is claimed under one lock: fresh = select + claim atomically, resume = pinned to the recorded account (unmapped resume blocks).
# A one-shot --no-session-persistence run has no claude session, so a private key is claimed instead of passing --session-id to claude.
KEY="$sid"
if [ -z "$KEY" ] && [ "$RESUME" = 0 ]; then
  KEY="$(cat /proc/sys/kernel/random/uuid)"; [ "$NOPERSIST" = 1 ] || { sid="$KEY"; out+=(--session-id "$sid"); }
fi
[ "$RESUME" = 0 ] || [[ "$sid" =~ ^[0-9a-f-]{36}$ ]] || { echo "fable-launch: --resume needs a session id (UUID)" >&2; exit 64; }
claim=(--session "$KEY" --lane "$LANE" --model "$model" --pid $$)
[ "$RESUME" = 0 ] || claim+=(--resume --evidence-log "$DEC_LOG")
[ -z "${FABLE_LAUNCH_ACK_UNKNOWN_EFFECT:-}" ] || claim+=(--ack-unknown-effect)
# Installed pin (A1221): a non-Fable --resume SID allocated by the pre-lane launcher is recorded in $RR_DIR/sid-map. That record is the allocation
# fact, so it is offered as the adoption (audited, by installed-rr-sid-map); session-claim still requires a prior launch row naming this session
# and account in the evidence log, a permitted account, and the unknown-effect ack. Without a record the resume stays blocked (session_unmapped).
if [ -z "${FABLE_LAUNCH_ADOPT_ACCOUNT:-}" ] && [ "$RESUME" = 1 ] && [ "$IS_FABLE" != 1 ] && [ -r "$RR_DIR/sid-map" ]; then
  _rr="$(awk -v s="$sid" '$1==s {a=$2} END{print a}' "$RR_DIR/sid-map" 2>/dev/null)"
  if [[ "$_rr" =~ ^[A-Za-z0-9._-]+$ ]]; then FABLE_LAUNCH_ADOPT_ACCOUNT="$_rr"; FABLE_LAUNCH_ADOPT_BY=installed-rr-sid-map; FABLE_LAUNCH_ADOPT_REASON="allocation recorded in the pre-lane round-robin sid-map"; fi
fi
if [ -n "${FABLE_LAUNCH_ADOPT_ACCOUNT:-}" ]; then claim+=(--adopt-account "$FABLE_LAUNCH_ADOPT_ACCOUNT" --adopt-by "${FABLE_LAUNCH_ADOPT_BY:-}" --adopt-reason "${FABLE_LAUNCH_ADOPT_REASON:-}"); fi
CL="$(python3 -I "$LANE_PY" session-claim "${claim[@]}")"; crc=$?
if [ $crc -ne 0 ]; then printf '%s\n' "$CL"; echo "fable-launch: no account selectable / session blocked (rc=$crc); nothing started, no fallback" >&2; exit $crc; fi
ACCT="$(printf '%s' "$CL" | jq -r '.account')"
[[ "$ACCT" =~ ^[A-Za-z0-9._-]+$ ]] || exit 64
f="$STORE/$ACCT"
[ -s "$f" ] || { echo "fable-launch: no stored credential for account '$ACCT'" >&2; python3 -I "$LANE_PY" session-abort --session "$KEY" >/dev/null 2>&1; exit 66; }
[ "$ROUTED" = 0 ] || dec_row launch
tok="$(cat "$f")"
# Paid-overage safeguard + inherited credential scrub: only the selected account's OAuth token may authenticate this process.
for _v in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY AWS_BEARER_TOKEN_BEDROCK; do
  [ -z "${!_v:-}" ] || { echo "fable-launch: inherited $_v scrubbed (OAuth account only, no paid/API path)" >&2; unset "$_v"; }
done
export CLAUDE_CODE_OAUTH_TOKEN="$tok"; unset tok
export FABLE_LAUNCH_ACCOUNT="$ACCT" FABLE_LAUNCH_MODEL="$model"
echo "fable-launch: account=$ACCT model=$model${effort:+ effort=$effort}" >&2
cmd=("$CLAUDE_BIN" "${out[@]}"); [ -z "$effort" ] || cmd+=(--effort "$effort")
[ ${#tail[@]} -eq 0 ] || cmd+=("${tail[@]}")   # caller payload from its first `--` on, after every injected option
# Supervised, never exec'd: the wrapper keeps the claim (same pid), forwards signals, and records a clean exit or an unknown-effect ending.
# The session id actually handed to the CLI: explicit --session-id X / =X / --resume X (also with --no-session-persistence) and the injected one.
# Empty only for a truly unpinned run, where the supervisor key is private and never reaches the CLI.
NATIVE_SID="$sid"
if [ "$HEADLESS" = 1 ]; then exec python3 -I "$LANE_PY" run --output-format "$OUTFMT" --native-sid "$NATIVE_SID" --account "$ACCT" --lane "$LANE" --session "$KEY" -- "${cmd[@]}"; fi
exec python3 -I "$LANE_PY" run --tty --account "$ACCT" --lane "$LANE" --session "$KEY" -- "${cmd[@]}"
