#!/usr/bin/env bash
# fable-native-agent-guard.sh — PreToolUse (Agent), A1169/A1221 (Joe 11-07); A1300 FFDR R5: the parent's lane comes from launch provenance.
# A native Agent child inherits its parent's account token, so the guard keeps the Fable/non-Fable account split by the model the parent was
# LAUNCHED on (fable-launch.sh exports FABLE_LAUNCH_ACCOUNT and FABLE_LAUNCH_MODEL together):
#  * Fable parent (FABLE_LAUNCH_MODEL is a Fable id: `fable` or `claude-fable-<suffix>`, any case; account-lane's lane_of grammar): the session
#    runs on the Fable-lane account, so any child whose model is not Fable is denied BEFORE the call; run it as a separate process on a
#    non-Fable account chosen by the launcher: fable-launch.sh --helper --model <m> -p "<prompt>".
#  * any other parent (a non-Fable FABLE_LAUNCH_MODEL, or a session fable-launch.sh did not start): a native Agent with a Fable model would run
#    Fable on a non-Fable account; denied, run it via fable-launch.sh.
#  * FABLE_LAUNCH_ACCOUNT set with FABLE_LAUNCH_MODEL empty: the launch provenance is incomplete; every Agent call is denied (fail closed).
# No policy is read: an account's current lane membership is not its session's lane (a pinned worker keeps the lane it was launched on, and
# one account may sit in both lanes). Deny texts name no account.
# Governed skills (.config/skill-routing/policy.json, A1300) go through fable-launch.sh --route-request, which picks the model by policy and keeps this same account split.
# Fable child with explicit effort high under a Fable parent: allowed.
# Under a Fable parent an omitted model and a Fable model without explicit effort high are denied, and unreadable input/no jq fail closed (so
# does incomplete provenance); elsewhere unreadable input fails open (declared residual).
set -uo pipefail
ACCT="${FABLE_LAUNCH_ACCOUNT:-}"; LM="${FABLE_LAUNCH_MODEL:-}"; LM="${LM,,}"   # bash lowercasing: the lane is known before any external command runs
FA=0; case "$LM" in fable|claude-fable-*) FA=1 ;; esac
UNK=0; [ -n "$ACCT" ] && [ -z "$LM" ] && UNK=1
JQ=$(command -v jq) || { [ "$FA$UNK" != 00 ] && { echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"fable-native-agent-guard: jq missing under a Fable parent or incomplete launch provenance, failing closed"}}'; }; exit 0; }
IN=$(cat) || IN=""
if ! printf '%s' "$IN" | "$JQ" -e . >/dev/null 2>&1; then
  [ "$FA$UNK" != 00 ] && "$JQ" -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"fable-native-agent-guard: unreadable tool input under a Fable parent or incomplete launch provenance, failing closed"}}'
  exit 0
fi
[ "$(printf '%s' "$IN" | "$JQ" -r '.tool_name // empty' 2>/dev/null)" = Agent ] || exit 0
M=$(printf '%s' "$IN" | "$JQ" -r '.tool_input.model // empty' 2>/dev/null | tr '[:upper:]' '[:lower:]')
E=$(printf '%s' "$IN" | "$JQ" -r '.tool_input.effort // empty' 2>/dev/null | tr '[:upper:]' '[:lower:]')
deny(){ "$JQ" -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; exit 0; }
isf(){ case "$1" in fable|claude-fable-*) return 0;; *) return 1;; esac; }
[ "$UNK" = 0 ] || deny "fable-native-agent-guard: FABLE_LAUNCH_ACCOUNT is set but FABLE_LAUNCH_MODEL is empty, so the lane this session was launched on is unknown; failing closed. Start the session through fable-launch.sh, which exports both (A1300 FFDR R5)."
if [ "$FA" = 1 ]; then
  [ -z "$M" ] && deny "fable-native-agent-guard: under a Fable parent a native Agent needs an explicit Fable model; an omitted model lets a named agent (coder, triage, ...) pin a non-Fable model on the Fable-lane account's token. Run non-Fable helpers via fable-launch.sh --helper --model <m> -p \"<prompt>\" (A1169)."
  if isf "$M"; then
    [ "$E" = high ] && exit 0
    deny "fable-native-agent-guard: a native Fable Agent under a Fable parent needs explicit effort high (got: ${E:-none}); xhigh/max are reasoned exceptions that run through fable-launch.sh with FABLE_LAUNCH_EFFORT_REASON, not a native Agent. Governed skill workflows: fable-launch.sh --route-request <file> -p \"<prompt>\". Otherwise prefer fable-launch.sh --model claude-fable-5-1 --effort high -p \"<prompt>\" (A1169)."
  fi
  deny "fable-native-agent-guard: this session runs Fable on the Fable-lane account; a native Agent child (model=$M) inherits that account. Run non-Fable helpers as a separate process on a non-Fable account chosen by the launcher: ~/.local/bin/fable-launch.sh --helper --model <sonnet|haiku> -p \"<prompt>\" (A1169)."
fi
if isf "$M"; then
  deny "fable-native-agent-guard: a native Agent with model=$M would run Fable on this session's account, which was not launched on the Fable lane. For a governed skill workflow use ~/.local/bin/fable-launch.sh --route-request <file> -p \"<prompt>\"; otherwise launch Fable on the Fable-lane account at high: ~/.local/bin/fable-launch.sh --model claude-fable-5-1 --effort high -p \"<prompt>\" (A1169)."
fi
exit 0
