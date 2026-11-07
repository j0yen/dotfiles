#!/usr/bin/env bash
# fable-native-agent-guard.sh — PreToolUse (Agent), A1169 (Joe 11-07 early switch). Keeps the Fable/non-Fable account split:
#  * parent launched by fable-launch.sh on jyen.pm (FABLE_LAUNCH_ACCOUNT=jyen.pm): a native Agent child inherits that token, so any
#    child whose model is not Fable is denied BEFORE the call; run it as a separate josephsyen process: fable-launch.sh --helper --model <m> -p "<prompt>".
#  * any other parent (josephsyen): a native Agent with a Fable model would run Fable on josephsyen; denied, run it via fable-launch.sh (jyen.pm, xhigh).
# Fable child under a jyen.pm Fable parent: allowed. An omitted model inherits the parent's model, so it follows the parent's account.
# Fails open on unreadable input only (no jq / not an Agent call).
set -uo pipefail
JQ=$(command -v jq) || exit 0
IN=$(cat) || exit 0
[ "$(printf '%s' "$IN" | "$JQ" -r '.tool_name // empty' 2>/dev/null)" = Agent ] || exit 0
M=$(printf '%s' "$IN" | "$JQ" -r '.tool_input.model // empty' 2>/dev/null | tr '[:upper:]' '[:lower:]')
ACCT="${FABLE_LAUNCH_ACCOUNT:-}"
deny(){ "$JQ" -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; exit 0; }
isf(){ case "$1" in fable|claude-fable-*) return 0;; *) return 1;; esac; }
if [ "$ACCT" = jyen.pm ]; then
  [ -z "$M" ] && exit 0
  isf "$M" && exit 0
  deny "fable-native-agent-guard: this session runs Fable on jyen.pm; a native Agent child (model=$M) inherits that account. Run non-Fable helpers as a separate josephsyen process: ~/.local/bin/fable-launch.sh --helper --model <sonnet|haiku> -p \"<prompt>\" (A1169)."
fi
if isf "$M"; then
  deny "fable-native-agent-guard: a native Agent with model=$M would run Fable on this session's account. Launch Fable on jyen.pm at xhigh instead: ~/.local/bin/fable-launch.sh --model claude-fable-5-1 --effort xhigh -p \"<prompt>\" (A1169)."
fi
exit 0
