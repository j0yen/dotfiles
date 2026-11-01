#!/usr/bin/env bash
# skill-marker.sh — UserPromptSubmit: a typed `/<skill> …` touches
# ${SKILL_MARKER_DIR:-~/.claude/state/skill-active}/<skill>.<session_id>.
# The harness expands a typed slash command inline with no Skill call, so
# fable-skill-spawn-gate.sh (which marks Skill-tool calls) never sees it.
# analysis-page-gate.sh reads the marker. Fails open (never blocks).

set -uo pipefail

JQ=$(command -v jq) || exit 0
INPUT=$(cat) || exit 0
[ -n "$INPUT" ] || exit 0

PROMPT=$(printf '%s' "$INPUT" | "$JQ" -r '.prompt // empty' 2>/dev/null) || exit 0
SESSION_ID=$(printf '%s' "$INPUT" | "$JQ" -r '.session_id // empty' 2>/dev/null) || SESSION_ID=""
NAME=$(printf '%s' "$PROMPT" | sed -nE '1s#^[[:space:]]*/([A-Za-z0-9_.-]+:)?([A-Za-z0-9_-]+)([[:space:]].*)?$#\2#p')
[ -n "$NAME" ] || exit 0
[ -d "${FABLE_SKILLS_DIR:-$HOME/.claude/skills}/$NAME" ] || exit 0

MARK_DIR=${SKILL_MARKER_DIR:-$HOME/.claude/state/skill-active}
mkdir -p "$MARK_DIR" 2>/dev/null && touch "$MARK_DIR/$NAME.${SESSION_ID:-nosession}" 2>/dev/null
exit 0
