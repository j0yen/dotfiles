#!/usr/bin/env bash
# dream-marker.sh — PreToolUse hook (Skill): when the dream skill is
# invoked, touch ~/.claude/.dream-active so prd-write-gate.sh lets PRD
# writes through for the next DREAM_TTL_MIN (default 180) minutes.
# Mechanical, not model-driven: the marker is set by the harness on the
# skill call itself, so a session that never invoked /dream cannot file a
# PRD. Fails open (never blocks).

set -uo pipefail

MARKER="${HOME}/.claude/.dream-active"
JQ=$(command -v jq) || exit 0
INPUT=$(cat) || exit 0
[ -n "$INPUT" ] || exit 0

SKILL=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.skill // empty' 2>/dev/null) || exit 0
case "$SKILL" in
    dream|*:dream)
        touch "$MARKER" 2>/dev/null
        ;;
esac
exit 0
