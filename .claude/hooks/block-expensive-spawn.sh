#!/usr/bin/env bash
# block-expensive-spawn.sh — PreToolUse hook: deny Agent/Task spawns that
# use an expensive model (opus/fable) or the "fork" subagent_type, per the
# CLAUDE.md model-routing ladder (haiku scout/runner/triage, sonnet
# coder/verifier; opus/fable/fork only on explicit ask).
#
# Reads the PreToolUse hook JSON on stdin: .tool_name, .tool_input.model,
# .tool_input.subagent_type. Fails OPEN on any parse error, since a bug
# here must never silently block a live buildloop's spawns.

set -uo pipefail

ALLOW_FLAG="${HOME}/.claude/.allow-expensive-spawn"
LOG_DIR="${HOME}/.cache"
LOG_FILE="${LOG_DIR}/spawn-guard.log"
mkdir -p "$LOG_DIR" 2>/dev/null

# Flip to 1 once no loop relies on inherited (unset) model defaulting to an
# expensive tier. While 0, a missing/empty model is allowed through (logged)
# rather than denied, since some existing spawns don't pass model explicitly.
DENY_UNSET=0

JQ=$(command -v jq) || exit 0

INPUT=$(cat) || exit 0
[ -n "$INPUT" ] || exit 0

MODEL=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.model // empty' 2>/dev/null) || exit 0
SUBAGENT_TYPE=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.subagent_type // empty' 2>/dev/null) || exit 0

deny() {
    local reason="$1"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
    exit 0
}

if [ -f "$ALLOW_FLAG" ]; then
    exit 0
fi

MODEL_LC=$(printf '%s' "$MODEL" | tr '[:upper:]' '[:lower:]')

if printf '%s' "$MODEL_LC" | grep -qE '(^|-)(opus|fable)($|-)' || [ "$SUBAGENT_TYPE" = "fork" ]; then
    deny "Expensive spawn blocked (opus/fable/fork). Use haiku scout/runner/triage or sonnet coder/verifier per CLAUDE.md ladder. Override: touch ~/.claude/.allow-expensive-spawn"
fi

if [ -z "$MODEL" ]; then
    if [ "$DENY_UNSET" -eq 1 ]; then
        deny "Spawn missing an explicit model: pass explicit model: per CLAUDE.md ladder. Override: touch ~/.claude/.allow-expensive-spawn"
    else
        printf '%s subagent_type=%s model=UNSET\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SUBAGENT_TYPE:-none}" >> "$LOG_FILE" 2>/dev/null
        exit 0
    fi
fi

exit 0
