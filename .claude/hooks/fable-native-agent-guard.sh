#!/usr/bin/env bash
# fable-native-agent-guard.sh — PreToolUse (Agent), A1169 (Joe 11-07 early switch). Keeps the Fable/non-Fable account split:
#  * parent launched by fable-launch.sh on jyen.pm (FABLE_LAUNCH_ACCOUNT=jyen.pm): a native Agent child inherits that token, so any
#    child whose model is not Fable is denied BEFORE the call; run it as a separate josephsyen process: fable-launch.sh --helper --model <m> -p "<prompt>".
#  * any other parent (josephsyen): a native Agent with a Fable model would run Fable on josephsyen; denied, run it via fable-launch.sh (jyen.pm, xhigh).
# Governed skills (5whysandrhyme, wwhtbt; .config/skill-routing/policy.json, A1300) go through fable-launch.sh --route-request, which picks Fable or Sonnet by policy and keeps this same account split.
# Fable child with explicit effort under a jyen.pm Fable parent: allowed.
# Under jyen.pm an omitted model and a Fable model without explicit effort xhigh|max are denied, and unreadable input/no jq fail closed; elsewhere unreadable input fails open (declared residual).
set -uo pipefail
ACCT="${FABLE_LAUNCH_ACCOUNT:-}"
JQ=$(command -v jq) || { [ "$ACCT" = jyen.pm ] && { echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"fable-native-agent-guard: jq missing under jyen.pm, failing closed"}}'; }; exit 0; }
IN=$(cat) || IN=""
if ! printf '%s' "$IN" | "$JQ" -e . >/dev/null 2>&1; then
  [ "$ACCT" = jyen.pm ] && "$JQ" -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"fable-native-agent-guard: unreadable tool input under jyen.pm, failing closed"}}'
  exit 0
fi
[ "$(printf '%s' "$IN" | "$JQ" -r '.tool_name // empty' 2>/dev/null)" = Agent ] || exit 0
M=$(printf '%s' "$IN" | "$JQ" -r '.tool_input.model // empty' 2>/dev/null | tr '[:upper:]' '[:lower:]')
E=$(printf '%s' "$IN" | "$JQ" -r '.tool_input.effort // empty' 2>/dev/null | tr '[:upper:]' '[:lower:]')
deny(){ "$JQ" -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; exit 0; }
isf(){ case "$1" in fable|claude-fable-*) return 0;; *) return 1;; esac; }
if [ "$ACCT" = jyen.pm ]; then
  [ -z "$M" ] && deny "fable-native-agent-guard: under jyen.pm a native Agent needs an explicit Fable model; an omitted model lets a named agent (coder, triage, ...) pin a non-Fable model on the jyen.pm token. Run non-Fable helpers via fable-launch.sh --helper --model <m> -p \"<prompt>\" (A1169)."
  if isf "$M"; then
    [ "$E" = high ] && exit 0
    deny "fable-native-agent-guard: a native Fable Agent under jyen.pm needs explicit effort high (got: ${E:-none}); xhigh/max are reasoned exceptions that run through fable-launch.sh with FABLE_LAUNCH_EFFORT_REASON, not a native Agent. Governed skill workflows: fable-launch.sh --route-request <file> -p \"<prompt>\". Otherwise prefer fable-launch.sh --model claude-fable-5-1 --effort high -p \"<prompt>\" (A1169)."
  fi
  deny "fable-native-agent-guard: this session runs Fable on jyen.pm; a native Agent child (model=$M) inherits that account. Run non-Fable helpers as a separate josephsyen process: ~/.local/bin/fable-launch.sh --helper --model <sonnet|haiku> -p \"<prompt>\" (A1169)."
fi
if isf "$M"; then
  deny "fable-native-agent-guard: a native Agent with model=$M would run Fable on this session's account. For a governed skill workflow use ~/.local/bin/fable-launch.sh --route-request <file> -p \"<prompt>\"; otherwise launch Fable on jyen.pm at high: ~/.local/bin/fable-launch.sh --model claude-fable-5-1 --effort high -p \"<prompt>\" (A1169)."
fi
exit 0
