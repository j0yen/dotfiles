#!/usr/bin/env bash
# fable-native-agent-guard.sh — PreToolUse (Agent), A1169/A1221 (Joe 11-07). Allowed accounts: Fable = jyen.pm; non-Fable = {josephsyen, jyen.tech} (round-robin by fable-launch.sh). Keeps the Fable/non-Fable account split:
#  * parent launched by fable-launch.sh on jyen.pm (FABLE_LAUNCH_ACCOUNT=jyen.pm): a native Agent child inherits that token, so any
#    child whose model is not Fable is denied BEFORE the call; run it as a separate round-robin (josephsyen|jyen.tech) process: fable-launch.sh --helper --model <m> -p "<prompt>".
#  * any other parent (josephsyen or jyen.tech): a native Agent with a Fable model would run Fable on a non-Fable account; denied, run it via fable-launch.sh (jyen.pm, xhigh).
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
    [ "$E" = xhigh ] && exit 0
    deny "fable-native-agent-guard: a native Fable Agent under jyen.pm needs explicit effort xhigh (got: ${E:-none}); max is not allowed without a ledger-backed path. Prefer fable-launch.sh --model claude-fable-5-1 --effort xhigh -p \"<prompt>\" (A1169)."
  fi
  deny "fable-native-agent-guard: this session runs Fable on jyen.pm; a native Agent child (model=$M) inherits that account. Run non-Fable helpers as a separate process on a non-Fable account (josephsyen or jyen.tech, chosen by the launcher's round-robin): ~/.local/bin/fable-launch.sh --helper --model <sonnet|haiku> -p \"<prompt>\" (A1169)."
fi
if isf "$M"; then
  deny "fable-native-agent-guard: a native Agent with model=$M would run Fable on this session's account. Launch Fable on jyen.pm at xhigh instead: ~/.local/bin/fable-launch.sh --model claude-fable-5-1 --effort xhigh -p \"<prompt>\" (A1169)."
fi
exit 0
