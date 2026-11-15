#!/usr/bin/env bash
# dream-marker.sh — touch ~/.claude/.dream-active so prd-write-gate.sh lets
# PRD writes through for the next DREAM_TTL_MIN (default 180) minutes.
# Two harness events set it, both mechanical (never model-driven):
#   PreToolUse (Skill)   — the model called the dream skill via the Skill tool
#   UserPromptSubmit     — the user typed `/dream …` (the harness expands a
#                          typed slash command inline; no Skill call happens,
#                          which is why a /dream typed on 2026-09-18 00:30 EDT
#                          was refused by the gate and needed the hand override)
# Fails open (never blocks).

set -uo pipefail

MARKER="${HOME}/.claude/.dream-active"
JQ=$(command -v jq) || exit 0
INPUT=$(cat) || exit 0
[ -n "$INPUT" ] || exit 0

SKILL=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.skill // empty' 2>/dev/null) || SKILL=""
PROMPT=$(printf '%s' "$INPUT" | "$JQ" -r '.prompt // empty' 2>/dev/null) || PROMPT=""

hit=0
case "$SKILL" in
    dream|*:dream) hit=1 ;;
esac
# typed form: optional leading whitespace, `/dream` as a whole word
if printf '%s' "$PROMPT" | grep -qE '^[[:space:]]*/dream([[:space:]]|$)'; then hit=1; fi

[ "$hit" = 1 ] && touch "$MARKER" 2>/dev/null
exit 0
