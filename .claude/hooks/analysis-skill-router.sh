#!/usr/bin/env bash
# analysis-skill-router.sh — UserPromptSubmit: a prompt that asks for analysis
# in explicit words gets a one-line pointer to the skill that does it.
#
# Joe 2026-10-24 4:2x PM "make sure the new skill /5whysandrhyme is always used
# for analysis. never try to analyze it without the skill." + "what about the
# WWIT analysis for future features?"
#
# Explicit phrases only (Fable review 10-24: a broad "why did" match fires on
# ordinary questions and teaches the model to ignore it):
#   five whys / 5 whys / rhyme check / and rhyme / post-mortem / root cause → /5whysandrhyme
#   wwhtbt / wwit / what would have to be true                              → /wwhtbt
# A prompt that already starts with the slash command is left alone. Each fire
# is logged to ${ANALYSIS_ROUTER_LOG:-~/.claude/state/analysis-router.jsonl}
# so the hit rate can be counted. analysis-page-gate.sh is the hard stop; this
# hook only points. Fails open.

set -uo pipefail

JQ=$(command -v jq) || exit 0
INPUT=$(cat) || exit 0
[ -n "$INPUT" ] || exit 0

PROMPT=$(printf '%s' "$INPUT" | "$JQ" -r '.prompt // empty' 2>/dev/null) || exit 0
[ -n "$PROMPT" ] || exit 0
SESSION_ID=$(printf '%s' "$INPUT" | "$JQ" -r '.session_id // empty' 2>/dev/null) || SESSION_ID=""

if printf '%s' "$PROMPT" | grep -qE '^[[:space:]]*/(5whysandrhyme|wwhtbt)([[:space:]]|$)'; then
    exit 0
fi

LC=$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]')
SKILL="" PHRASE=""
if PHRASE=$(printf '%s' "$LC" | grep -oE "\b(wwhtbt|wwit|what would have to be true)\b" | head -1) && [ -n "$PHRASE" ]; then
    SKILL=wwhtbt
elif PHRASE=$(printf '%s' "$LC" | grep -oE "\b(five|5) whys\b|\brhyme check\b|\band rhyme\b|\bpost-?mortem\b|\broot[- ]cause\b" | head -1) && [ -n "$PHRASE" ]; then
    SKILL=5whysandrhyme
fi
[ -n "$SKILL" ] || exit 0

LOG=${ANALYSIS_ROUTER_LOG:-$HOME/.claude/state/analysis-router.jsonl}
mkdir -p "$(dirname "$LOG")" 2>/dev/null
"$JQ" -nc --arg ts "$(date -Is)" --arg sid "$SESSION_ID" --arg skill "$SKILL" --arg phrase "$PHRASE" \
    --arg seat "${WM_SEAT:-}" '{ts:$ts,session:$sid,seat:$seat,skill:$skill,phrase:$phrase}' >>"$LOG" 2>/dev/null

echo "analysis-skill-router: \"$PHRASE\" → run /$SKILL (Skill tool; from a non-Fable session spawn Agent(model=fable, effort=max) that invokes it). Mitigate first; never write the analysis by hand (Joe 10-24)."
exit 0
