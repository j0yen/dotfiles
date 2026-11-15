#!/usr/bin/env bash
# dream-marker.sh — touch this session's own marker
# ${SKILL_MARKER_DIR:-~/.claude/state/skill-active}/dream-prd.<session_id> so
# prd-write-gate.sh lets THIS session's PRD writes through for the next
# DREAM_TTL_MIN (default 180) minutes. Two harness events set it, both
# mechanical (never model-driven):
#   PreToolUse (Skill)   — the model called the dream skill via the Skill tool
#   UserPromptSubmit     — the user typed `/dream …` (the harness expands a
#                          typed slash command inline; no Skill call happens,
#                          which is why a /dream typed on 2026-09-18 00:30 EDT
#                          was refused by the gate and needed the hand override)
# The marker directory is created when absent. With an empty or missing
# session_id nothing is written (never a shared marker). The legacy home-wide
# ~/.claude/.dream-active is no longer written (PRD
# dream-prd-marker-per-session). This hook and the gate are the only writers
# of dream-prd.*; the sibling dream.<sid> belongs to fable-skill-spawn-gate.sh
# and skill-marker.sh. Fails open (never blocks).

set -uo pipefail

MARKER_DIR="${SKILL_MARKER_DIR:-$HOME/.claude/state/skill-active}"
JQ=$(command -v jq) || exit 0
INPUT=$(cat) || exit 0
[ -n "$INPUT" ] || exit 0

SKILL=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.skill // empty' 2>/dev/null) || SKILL=""
PROMPT=$(printf '%s' "$INPUT" | "$JQ" -r '.prompt // empty' 2>/dev/null) || PROMPT=""
SID=$(printf '%s' "$INPUT" | "$JQ" -r '.session_id // empty' 2>/dev/null) || SID=""

hit=0
case "$SKILL" in
    dream|*:dream) hit=1 ;;
esac
# typed form: optional leading whitespace, `/dream` as a whole word
if printf '%s' "$PROMPT" | grep -qE '^[[:space:]]*/dream([[:space:]]|$)'; then hit=1; fi

[ "$hit" = 1 ] || exit 0
[ -n "$SID" ] || exit 0
mkdir -p "$MARKER_DIR" 2>/dev/null && touch "$MARKER_DIR/dream-prd.$SID" 2>/dev/null
exit 0
