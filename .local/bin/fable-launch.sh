#!/usr/bin/env bash
# fable-launch.sh [--helper] <claude args incl. --model M --effort E>   (A1169, A1221; Joe 11-07 10:38 AM routing)
# Account is chosen by the ACTUAL selected model AND durable per-lane exhaustion state (.local/lib/account-lane.py, A1300/A1301):
#   Fable -> mcphost.dev until its Fable lane is exhausted, then jyen.pm; other models -> the policy's nonfable primaries (jyen.pm) by the persistent round-robin (A1221, counter in the lane state under the same lock; exhausted primaries skipped; a missing credential gives the slot back and never rotates), mcphost.dev reserve only when ALL primaries are exhausted (.config/account-lanes/policy.json).
#   Reserve use is lane-state driven: no usage-percent or calendar input. Fable effort default high; xhigh|max only with FABLE_LAUNCH_EFFORT_REASON. No selectable account = structured block, exit 75 (no paid/API fallback).
#   Exit: 75 lane blocked/transfer unsupported, 76 state or policy invalid, 77 unknown-effect resume needs FABLE_LAUNCH_ACK_UNKNOWN_EFFECT, 73 duplicate live session.
#   Headless (-p/--print) launches run supervised so a usage-limit failure is classified and recorded; interactive launches still exec.
# Process-local only: exports CLAUDE_CODE_OAUTH_TOKEN for the exec'd claude. No rotation, no shared default edits, no token output.
# A Fable parent's native child agents inherit this env (mcphost.dev); use `fable-launch.sh --helper --model sonnet ...` for separate-process helpers on the nonfable lane.
# A1300 E4: --helper also exports WM_HELPER=1 + WM_PARENT_SID + WM_TASK (WM_SEAT is kept); see the four Stop-obligation hooks.
# A1300 managed skill route: `--route-request FILE` (JSON {task_id,skill,decision_class?,evidence_refs?,escalation?,review?}; task text is
# data, never interpolated) is resolved by skill-route-resolve.py against .config/skill-routing/policy.json. A denied or ungoverned
# route exits 64 before anything starts; an allowed route supplies --model/--effort (a conflicting --model/--effort is refused), a
# task-linked row is appended to ${SKILL_ROUTING_DECISIONS:-~/.local/state/skill-routing/decisions.jsonl}, and the worker env drops the
# ctl seat/model markers. Policy picks model+effort only; the account still follows the model exactly as below (policy cannot grant account or spend changes).
# A1300 FFDR (spec r2 R4), routed launches only; every row stays fourteen fields; denials are one `denied` row + exit 64 before the claim:
#   R4.1 the worker also gets SKILL_ROUTE_ROLE (author|review), SKILL_ROUTE_SESSION (the id handed to the CLI), SKILL_ROUTE_SCOPE_ID (empty for an author).
#   R4.2 nested-dispatch: refused when the caller's inherited SKILL_ROUTE_ROLE is review, or when skill-route-terminal.py review-ancestor
#        finds a review session's claim pid (pid + start time) or a claude / account-lane.py run process carrying a review id among our ancestors.
#   R4.3 self-review (a review launch whose id is the caller's SKILL_ROUTE_SESSION); session-id-grammar (a fresh launch's pre-drawn id must be a
#        canonical lowercase UUID); session-reuse (a fresh launch's pre-drawn id must appear in no launch row; checked under the guard lock).
#   R4.4 unchanged-review-replay, under the guard lock after the duplicate guard: a resumed review that completed is refused; a fresh review is
#        refused while a same task/skill/scope_id review is running or completed; failed/interrupted/unknown priors block unless review.replay
#        declares exactly them, and then one `replay` row (reasons = the declaration as compact JSON) precedes the launch row; never-dispatched
#        priors do not block. Outcomes come from skill-route-terminal.py session under timeout 10; any reader failure refuses.
#   R4.5 the reader sits beside the resolver (else ~/.local/lib); SKILL_ROUTE_TERMINAL overrides it only under FABLE_LAUNCH_TEST=1.
#   R4.6 SKILL_ROUTE_POLICY and SKILL_ROUTE_LEDGER_IDS are refused outside FABLE_LAUNCH_TEST=1; SKILL_ROUTING_DECISIONS stays honoured (proof roots).
set -u
IN_ROLE="${SKILL_ROUTE_ROLE:-}"; IN_SESSION="${SKILL_ROUTE_SESSION:-}"   # R4.2/R4.3: the caller's routed role and session, before we export ours
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
  for _v in SKILL_ROUTE_POLICY SKILL_ROUTE_LEDGER_IDS; do   # R4.6 (F16): the routing policy and the ledger are fixed for launches
    [ -z "${!_v:-}" ] || { echo "fable-launch: $_v override refused (skill-routing policy and ledger are fixed outside FABLE_LAUNCH_TEST=1)" >&2; exit 64; }
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
# Review scope (PRD fable-launch-review-scope-guard): role comes only from a verifying review.snapshot manifest, never from env or a label.
R_ROLE=author; R_SCOPE=""; R_SCOPE_ID=""; R_REVIEW=none; R_SNAP=""; R_REPLAY=""; REPLAY_WHY=""
DEC_LOG="${SKILL_ROUTING_DECISIONS:-$HOME/.local/state/skill-routing/decisions.jsonl}"
dec_row() { # decision, extra jq args...
  mkdir -p "$(dirname "$DEC_LOG")" 2>/dev/null
  jq -nc --arg ts "$(date -Is)" --arg d "$1" --arg tid "${R_TASK:-}" --arg sk "${R_SKILL:-}" --arg route "${R_ROUTE:-}" \
    --arg m "${model:-}" --arg e "${effort:-}" --arg acct "${ACCT:-}" --arg sid "${sid:-}" --arg why "${R_WHY:-}" --argjson resume "${R_RESUME:-false}" \
    --arg role "${R_ROLE:-author}" --arg scope "${R_SCOPE:-}" --arg scope_id "${R_SCOPE_ID:-}" \
    '{ts:$ts,decision:$d,task_id:$tid,skill:$sk,route:$route,model:$m,effort:$e,account:$acct,session:$sid,resume:$resume,reasons:$why,role:$role,scope:$scope,scope_id:$scope_id}' >>"$DEC_LOG" 2>/dev/null
}
if [ -n "$ROUTE_REQ" ]; then
  ROUTED=1
  HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
  RESOLVER="$HERE/../lib/skill-route-resolve.py"; [ -r "$RESOLVER" ] || RESOLVER="$HOME/.local/lib/skill-route-resolve.py"
  [ "${FABLE_LAUNCH_TEST:-0}" = 1 ] && [ -n "${SKILL_ROUTE_RESOLVER:-}" ] && RESOLVER="$SKILL_ROUTE_RESOLVER"
  TERMINAL="$HERE/../lib/skill-route-terminal.py"; [ -r "$TERMINAL" ] || TERMINAL="$HOME/.local/lib/skill-route-terminal.py"   # R4.5
  [ "${FABLE_LAUNCH_TEST:-0}" = 1 ] && [ -n "${SKILL_ROUTE_TERMINAL:-}" ] && TERMINAL="$SKILL_ROUTE_TERMINAL"
  [ -r "$ROUTE_REQ" ] && [ -r "$RESOLVER" ] || { echo "fable-launch: route request or resolver unreadable; refusing (fail closed)" >&2; exit 64; }
  RQ="$(mktemp)"; trap 'rm -f "$RQ"' EXIT
  jq -c --arg m "$model" --arg e "$effort" '.requested = ((.requested // {}) + (if $m!="" then {model:$m} else {} end) + (if $e!="" then {effort:$e} else {} end))' "$ROUTE_REQ" >"$RQ" 2>/dev/null \
    || { echo "fable-launch: route request is not valid JSON; refusing (fail closed)" >&2; exit 64; }
  R_TASK="$(jq -r '.task_id // ""' "$RQ" 2>/dev/null)"; R_SKILL="$(jq -r '.skill // ""' "$RQ" 2>/dev/null)"
  R_REVIEW="$(jq -r 'if (.review|type)=="object" then (if (.review|has("snapshot")) then "snapshot" else "object" end) else "none" end' "$RQ" 2>/dev/null)"
  R_SNAP="$(jq -r '.review.snapshot | if type=="string" then . else "" end' "$RQ" 2>/dev/null)"
  if ! RES="$(python3 -I "$RESOLVER" --file "$RQ")"; then
    R_WHY="$(printf '%s' "$RES" | jq -r '.error // "denied"' 2>/dev/null)"
    dec_row denied; echo "fable-launch: route DENIED, nothing started: $R_WHY" >&2
    echo "fable-launch: fix the request (task_id, decision_class, escalation{reason,evidence:[ledger:|file:|pr:|run:|commit:|page: refs]}) or use the baseline route; see .config/skill-routing/policy.json" >&2; exit 64
  fi
  [ "$(printf '%s' "$RES" | jq -r '.governed')" = true ] || { echo "fable-launch: skill '$R_SKILL' is not governed by skill routing; use a plain launch" >&2; exit 64; }
  model="$(printf '%s' "$RES" | jq -r '.model_id')"; effort="$(printf '%s' "$RES" | jq -r '.effort')"
  R_ROUTE="$(printf '%s' "$RES" | jq -r '.route')"; R_WHY="$(printf '%s' "$RES" | jq -r '.reasons|join("; ")')"
  R_REPLAY="$(printf '%s' "$RES" | jq -c '.review.replay // empty')"   # the resolver-validated declaration (R2), prior sorted
  rm -f "$RQ"; trap - EXIT
  nout=(); j=0; while [ $j -lt ${#out[@]} ]; do case "${out[$j]}" in --model) j=$((j+2)); continue ;; --model=*) ;; *) nout+=("${out[$j]}") ;; esac; j=$((j+1)); done
  out=("${nout[@]}" --model "$model")
  # One permission_mode source: the resolver's echo (validated against the policy) is the only value passed to claude.
  PMODE="$(printf '%s' "$RES" | jq -r '.permission_mode // empty')"
  if [ -n "$PMODE" ]; then
    nout=(); j=0; while [ $j -lt ${#out[@]} ]; do
      case "${out[$j]}" in
        --permission-mode) [ "${out[$((j+1))]:-}" = "$PMODE" ] || { echo "fable-launch: --permission-mode '${out[$((j+1))]:-}' conflicts with the resolved permission_mode '$PMODE'; refusing" >&2; exit 64; }; j=$((j+2)); continue ;;
        --permission-mode=*) [ "${out[$j]#--permission-mode=}" = "$PMODE" ] || { echo "fable-launch: ${out[$j]} conflicts with the resolved permission_mode '$PMODE'; refusing" >&2; exit 64; } ;;
        *) nout+=("${out[$j]}") ;;
      esac; j=$((j+1)); done
    out=("${nout[@]}" --permission-mode "$PMODE")
  fi
  # Review scope: a request naming review.snapshot launches as a review only if the manifest passes four checks, in order (fail closed, exit 64):
  # line-rule (sha256sum's own line shape, LF-terminated), no-prd (a PRD-<slug>.md basename), prd-repeat (one PRD basename, two digests),
  # sha256sum (--check from the manifest's own directory). scope_id = sha256 of the "<sha256>  <basename>" lines, LC_ALL=C sort -u.
  if [ "$R_REVIEW" = snapshot ]; then
    R_ROLE=review; R_SCOPE="$(readlink -f -- "$R_SNAP" 2>/dev/null)" || R_SCOPE="$R_SNAP"; [ -n "$R_SCOPE" ] || R_SCOPE="$R_SNAP"
    snap_refuse() { R_WHY="review snapshot $R_SCOPE: $1"; dec_row denied; echo "fable-launch: review snapshot refused, nothing started: $R_WHY" >&2; exit 64; }
    M="$R_SCOPE"; ln=""
    if [ -f "$M" ] && [ -r "$M" ]; then ln="$(LC_ALL=C grep -Evn '^[0-9a-f]{64}  [^[:space:]]+$' -- "$M" 2>/dev/null | head -1 | cut -d: -f1)"; fi
    [[ "$ln" =~ ^[0-9]+$ ]] || ln=0
    { [ -f "$M" ] && [ -r "$M" ] && [ -s "$M" ] && [ "$(tail -c1 -- "$M" | od -An -tx1 | tr -d ' \n')" = 0a ] \
      && ! LC_ALL=C grep -Evq '^[0-9a-f]{64}  [^[:space:]]+$' -- "$M"; } || snap_refuse "line-rule failed at line $ln"
    canon() { LC_ALL=C awk '{n=split($2,p,"/"); print $1 "  " p[n]}' "$M" | LC_ALL=C sort -u; }
    R_SCOPE_ID="$(canon | sha256sum | cut -d' ' -f1)"
    canon | LC_ALL=C grep -Eq '^[0-9a-f]{64}  PRD-[a-z0-9-]+\.md$' || snap_refuse "no-prd (no listed basename matches PRD-<slug>.md)"
    rep="$(canon | LC_ALL=C awk '$2 ~ /^PRD-[a-z0-9-]+\.md$/ {print $2}' | LC_ALL=C sort | uniq -d | head -1)"
    [ -z "$rep" ] || { R_SCOPE_ID=""; snap_refuse "prd-repeat $rep (one PRD basename listed with two digests)"; }
    ( cd -- "$(dirname -- "$M")" && sha256sum --check --quiet --strict -- "$(basename -- "$M")" ) >&2 || snap_refuse "sha256sum --check failed from $(dirname -- "$M")"
    # The guard sees a launch only through its id in argv, so a fresh review must pre-draw it (a resume carries its id already).
    [ "$SIDARG" = 1 ] || [ "$RESUME" = 1 ] || { R_WHY="review launch needs a pre-drawn --session-id so the guard can see it"; dec_row denied; echo "fable-launch: $R_WHY; nothing started" >&2; exit 64; }
  elif [ "$R_REVIEW" = object ]; then
    echo "fable-launch: review object without snapshot: launching as author (unbindable as a Review: line once the lint PRD is installed)" >&2
    R_WHY="${R_WHY:+$R_WHY; }review-without-snapshot"
  fi
  # R4.2 nested dispatch and R4.3 self-review / id grammar (A1300 FFDR), before the guard lock and the claim: one denied row, exit 64.
  route_deny(){ R_WHY="$1"; dec_row denied; echo "fable-launch: $R_WHY; nothing started" >&2; exit 64; }
  [ "$IN_ROLE" != review ] || route_deny "nested-dispatch: launched from inside review session ${IN_SESSION:-(unnamed)} (inherited SKILL_ROUTE_ROLE=review); a review dispatches no routed work"
  [ "$R_ROLE" != review ] || [ -z "$IN_SESSION" ] || [ "$sid" != "$IN_SESSION" ] || route_deny "self-review: review launch id $sid is the caller's own session (SKILL_ROUTE_SESSION)"
  if [ "$RESUME" = 0 ] && [ "$SIDARG" = 1 ] && ! [[ "$sid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    route_deny "session-id-grammar: pre-drawn --session-id '$sid' is not a canonical lowercase UUID"
  fi
  SELF=(); [ -z "$sid" ] || SELF=(--self "$sid")
  ANC="$(timeout 10 python3 -I "$TERMINAL" --decisions "$DEC_LOG" review-ancestor --pid $$ "${SELF[@]}" 2>/dev/null)" \
    && ANC_SID="$(printf '%s' "$ANC" | jq -er 'if type=="object" and has("review_session") then (.review_session // "") else error("shape") end' 2>/dev/null)" \
    || route_deny "nested-dispatch check failed (skill-route-terminal.py review-ancestor: non-zero exit, timeout or unparsable output); refusing (fail closed)"
  [ -z "$ANC_SID" ] || route_deny "nested-dispatch: ancestor process of review session $ANC_SID ($(printf '%s' "$ANC" | jq -r '.reason' 2>/dev/null))"
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
  [ -z "$dup" ] || { [ "$ROUTED" = 0 ] || { R_WHY="session $sid already running (pid ${dup% }); not resuming a duplicate"; dec_row denied; }; echo "fable-launch: session $sid already running (pid $dup); not resuming a duplicate" >&2; exit 73; }
fi
if [ "$ROUTED" = 1 ]; then
  # Guard lock: the duplicate scan, both resume rules, the session claim and the launch row run under one flock (bounded 30 s), released
  # before the CLI starts, so two same-scope launches started at once are serialized. Any failure to take it is a denied row, never an unlocked scan.
  if ! { mkdir -p "$(dirname "$DEC_LOG")" 2>/dev/null && { exec 9>"${DEC_LOG}.guard.lock"; } 2>/dev/null && flock -w 30 9; }; then
    R_WHY="guard lock ${DEC_LOG}.guard.lock not taken (unopenable, flock failed or 30 s wait expired)"; dec_row denied; echo "fable-launch: $R_WHY; nothing started" >&2; exit 73
  fi
  # Same-session resume must keep the recorded route; a changed model/effort needs a new task session, not a silent switch.
  R_RESUME=false
  if [ -n "$sid" ] && [ "$SIDARG" = 0 ] && [ -r "$DEC_LOG" ]; then
    R_RESUME=true
    prev="$(jq -R -r --arg s "$sid" 'fromjson? | objects | select(.session==$s and .decision=="launch")|"\(.model)/\(.effort)"' "$DEC_LOG" 2>/dev/null | tail -1)"
    [ -z "$prev" ] || [ "$prev" = "$model/$effort" ] || { R_WHY="resume route $model/$effort differs from session's recorded $prev"; dec_row denied; echo "fable-launch: $R_WHY; start a new session for the new route" >&2; exit 64; }
  fi
  # A resumed session keeps its recorded role and scope_id (latest launch row for the session, any task; a role other than review = author).
  if [ "$RESUME" = 1 ] && [ -r "$DEC_LOG" ]; then
    prevrs="$(jq -R -r --arg s "$sid" 'fromjson? | objects | select(.session==$s and .decision=="launch")|"\(if .role == "review" then "review" else "author" end)/\(.scope_id // "")"' "$DEC_LOG" 2>/dev/null | tail -1)"
    [ -z "$prevrs" ] || [ "$prevrs" = "${R_ROLE:-author}/${R_SCOPE_ID:-}" ] || { R_WHY="resume role/scope differs: request ${R_ROLE:-author}/${R_SCOPE_ID:-}, session's recorded $prevrs"; dec_row denied; echo "fable-launch: $R_WHY; start a new session" >&2; exit 64; }
  fi
  # Duplicate dispatch, keyed on (task, skill, role, scope_id): a session's role is that of its latest launch row for the pair; a live author
  # blocks another author, a live review blocks another review of the same scope_id; every other pairing proceeds.
  if [ -r "$DEC_LOG" ]; then
    declare -A G_ROLE=() G_SCOPE=(); G_ORDER=()
    while IFS=$'\t' read -r gs gr gsc; do
      [ -n "${G_ROLE[$gs]+x}" ] || G_ORDER+=("$gs"); G_ROLE[$gs]="$gr"; G_SCOPE[$gs]="$gsc"
    done < <(jq -R -r --arg t "$R_TASK" --arg k "$R_SKILL" 'fromjson? | objects | select(.task_id==$t and .skill==$k and .decision=="launch" and (.session|type)=="string" and .session!="") | [.session, (if .role == "review" then "review" else "author" end), (.scope_id // "")] | @tsv' "$DEC_LOG" 2>/dev/null)
    for psid in "${G_ORDER[@]}"; do
      [ "$psid" = "$sid" ] && continue
      if [ "$R_ROLE" = review ]; then
        [ "${G_ROLE[$psid]}" = review ] && [ "${G_SCOPE[$psid]}" = "$R_SCOPE_ID" ] || continue
        why="task $R_TASK/$R_SKILL already has a live review of scope_id $R_SCOPE_ID (session $psid)"
      else
        [ "${G_ROLE[$psid]}" = author ] || continue
        why="task $R_TASK/$R_SKILL already has a live worker (session $psid)"
      fi
      if ps -eo args= | grep -F -- "$psid" | grep -vq grep; then R_WHY="$why"; dec_row denied; echo "fable-launch: $R_WHY; not dispatching a duplicate" >&2; exit 73; fi
    done
  fi
  # R4.3 session-reuse: a fresh launch's pre-drawn id appears in no launch row (under the lock: two launches with one new id cannot both pass).
  if [ "$RESUME" = 0 ] && [ -n "$sid" ] && [ -r "$DEC_LOG" ] \
     && jq -R -e --arg s "$sid" 'fromjson? | objects | select(.decision=="launch" and .session==$s)' "$DEC_LOG" >/dev/null 2>&1; then
    route_deny "session-reuse: pre-drawn --session-id $sid already appears in a launch row; draw a new id"
  fi
  # R4.4 unchanged review replay (amends A1719 AC 5's resume-after-clean vector and AC 6): outcomes from the reader, never from argv or labels.
  if [ "$R_ROLE" = review ]; then
    [ ! -e "$DEC_LOG" ] || { [ -f "$DEC_LOG" ] && [ -r "$DEC_LOG" ]; } || route_deny "unchanged-review-replay check failed: decisions log $DEC_LOG present but unreadable or not a regular file; refusing (fail closed)"
    # rd_outcome SID: the reader's terminal outcome (timeout 10; non-zero exit, timeout or unparsable output refuses; a reply about another
    # session or with no known outcome counts as unknown)
    rd_outcome(){
      local o; o="$(timeout 10 python3 -I "$TERMINAL" --decisions "$DEC_LOG" session "$1" 2>/dev/null)" && printf '%s' "$o" | jq -e 'type=="object"' >/dev/null 2>&1 \
        || route_deny "unchanged-review-replay check failed (skill-route-terminal.py session $1: non-zero exit, timeout or unparsable output); refusing (fail closed)"
      printf '%s' "$o" | jq -r --arg s "$1" 'if .session==$s and (.terminal.outcome|IN("absent","running","interrupted","completed","never-dispatched","failed","unknown")) then .terminal.outcome else "unknown" end'
    }
    if [ "$RESUME" = 1 ]; then
      [ -z "$R_REPLAY" ] || route_deny "stale replay declaration: review.replay on a resume (a resume continues its own session; a declaration belongs to a fresh review launch)"
      if [ -e "$DEC_LOG" ]; then
        oc="$(rd_outcome "$sid")" || exit 64   # rd_outcome's own refusal already wrote the denied row
        [ "$oc" != completed ] || route_deny "unchanged-review-replay: review session $sid already completed; resuming it would review the same bytes again; freeze a new manifest that adds its result/findings or the disposition file"
      fi
    else
      PRIORS=(); [ ! -e "$DEC_LOG" ] || mapfile -t PRIORS < <(jq -R -r --arg t "$R_TASK" --arg k "$R_SKILL" --arg sc "$R_SCOPE_ID" --arg me "$sid" \
        'fromjson? | objects | select(.decision=="launch" and .task_id==$t and .skill==$k and .role=="review" and (.scope_id // "")==$sc and (.session|type)=="string" and .session!="" and .session!=$me) | .session' "$DEC_LOG" 2>/dev/null | awk '!seen[$0]++')
      BLOCK=(); OUTC='{}'
      for psid in "${PRIORS[@]}"; do
        oc="$(rd_outcome "$psid")" || exit 64
        case "$oc" in
          running|completed) route_deny "unchanged-review-replay: scope_id $R_SCOPE_ID already reviewed by $psid ($oc); freeze a new manifest that adds the prior review's result/findings or the disposition file" ;;
          failed|interrupted|unknown|absent) BLOCK+=("$psid"); OUTC="$(jq -c --arg s "$psid" --arg o "$oc" '.[$s]=(if $o=="absent" then "unknown" else $o end)' <<<"$OUTC")" ;;
        esac
      done
      WANT="$(printf '%s\n' "${BLOCK[@]}" | LC_ALL=C sort | jq -R -s -c 'split("\n") | map(select(length>0))')"
      if [ "${#BLOCK[@]}" = 0 ]; then
        [ -z "$R_REPLAY" ] || route_deny "stale replay declaration: scope_id $R_SCOPE_ID has no failed, interrupted or unknown prior review to declare; drop review.replay"
      elif [ -z "$R_REPLAY" ] || [ "$(printf '%s' "$R_REPLAY" | jq -c '.prior')" != "$WANT" ]; then
        route_deny "unchanged-review-replay: scope_id $R_SCOPE_ID has prior review(s) that ended without a clean result: $(jq -r 'to_entries|map("\(.key) (\(.value))")|join(", ")' <<<"$OUTC")${R_REPLAY:+ (declared prior $(printf '%s' "$R_REPLAY" | jq -c '.prior') is not that set)}; declare review.replay {reason, evidence:[ledger:...], prior:$WANT}"
      else
        REPLAY_WHY="$(jq -cn --argjson p "$WANT" --argjson o "$OUTC" --argjson r "$R_REPLAY" '{prior:$p,prior_outcomes:$o,reason:$r.reason,evidence:$r.evidence}')"
      fi
    fi
  fi
  if [ -z "$sid" ]; then sid="$(cat /proc/sys/kernel/random/uuid)"; out+=(--session-id "$sid"); fi
  # Isolate the worker from the ctl seat: no ctl markers, no inherited model overrides.
  unset WM_SEAT ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL CLAUDE_CODE_SUBAGENT_MODEL
  export SKILL_ROUTE_TASK_ID="$R_TASK" SKILL_ROUTE_SKILL="$R_SKILL" SKILL_ROUTE_ROUTE="$R_ROUTE" SKILL_ROUTE_EFFORT="$effort"
  export SKILL_ROUTE_ROLE="$R_ROLE" SKILL_ROUTE_SESSION="$sid" SKILL_ROUTE_SCOPE_ID="$R_SCOPE_ID"   # R4.1
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
if [ "$ROUTED" = 1 ]; then   # a declared replay row (R4.4) immediately precedes the launch row; the guard lock is released before the CLI starts
  [ -z "$REPLAY_WHY" ] || { _why="$R_WHY"; R_WHY="$REPLAY_WHY"; dec_row replay; R_WHY="$_why"; }
  dec_row launch; exec 9>&-
fi
tok="$(cat "$f")"
# Paid-overage safeguard + inherited credential scrub: only the selected account's OAuth token may authenticate this process.
for _v in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY AWS_BEARER_TOKEN_BEDROCK; do
  [ -z "${!_v:-}" ] || { echo "fable-launch: inherited $_v scrubbed (OAuth account only, no paid/API path)" >&2; unset "$_v"; }
done
export CLAUDE_CODE_OAUTH_TOKEN="$tok"; unset tok
export FABLE_LAUNCH_ACCOUNT="$ACCT" FABLE_LAUNCH_MODEL="$model"
# A1300 E4: a --helper child keeps its parent seat marker (every gate stays enforced) and adds its own WM_HELPER marker with parent + task provenance;
# only the four Stop-obligation hooks read WM_HELPER. A non-helper launch carries no helper marker.
if [ "$HELPER" = 1 ]; then export WM_HELPER=1 WM_PARENT_SID="${WM_PARENT_SID:-${CLAUDE_SESSION_ID:-unknown}}" WM_TASK="${WM_TASK:-${R_TASK:-}}"; else unset WM_HELPER WM_PARENT_SID WM_TASK; fi
echo "fable-launch: account=$ACCT model=$model${effort:+ effort=$effort}" >&2
cmd=("$CLAUDE_BIN" "${out[@]}"); [ -z "$effort" ] || cmd+=(--effort "$effort")
[ ${#tail[@]} -eq 0 ] || cmd+=("${tail[@]}")   # caller payload from its first `--` on, after every injected option
# Supervised, never exec'd: the wrapper keeps the claim (same pid), forwards signals, and records a clean exit or an unknown-effect ending.
# The session id actually handed to the CLI: explicit --session-id X / =X / --resume X (also with --no-session-persistence) and the injected one.
# Empty only for a truly unpinned run, where the supervisor key is private and never reaches the CLI.
NATIVE_SID="$sid"
if [ "$HEADLESS" = 1 ]; then exec python3 -I "$LANE_PY" run --output-format "$OUTFMT" --native-sid "$NATIVE_SID" --account "$ACCT" --lane "$LANE" --session "$KEY" -- "${cmd[@]}"; fi
exec python3 -I "$LANE_PY" run --tty --account "$ACCT" --lane "$LANE" --session "$KEY" -- "${cmd[@]}"
