#!/usr/bin/env bash
# fable-skill-spawn-gate.sh — PreToolUse (Skill): a non-Fable turn that calls a
# skill whose SKILL.md frontmatter says `fable-spawn: true` is told to spawn a
# Fable subagent instead.
#
# Those skills pin `model: fable` + `effort: max` (/dream vibecode-kit#4,
# /5whysandrhyme, /wwhtbt; Joe 2026-10-24). Invoked inline from an Opus seat
# (rb/r7/ctl/aide), the pin switches the session model for that turn, and a
# model switch rebuilds the whole prompt cache. A subagent runs in its own
# context, so the seat's cache stays warm (Joe 2026-10-24 "can rb and r7 spawn
# a dream agent and avoid rebuilding the whole prompt cache?").
#
# The gated set is read from the skill's own frontmatter, never a hand list
# (FABLE_SKILLS_DIR overrides ~/.claude/skills for tests). Generalizes
# dream-spawn-gate.sh (dotfiles#91).
#
# Model detection is per CALL, same method as probe-gate.sh: find the
# transcript line whose assistant content holds this tool_use_id and read its
# model (a subagent's turns carry their own model). Fable → allow. Unknown →
# allow (fail open). Anything else → deny with the spawn recipe.
# A typed `/<skill>` is expanded by the harness without a Skill call, so Joe's
# own typed form is never gated (skill-marker.sh marks it instead).
#
# Every ALLOWED Skill call (any skill) touches
# ${SKILL_MARKER_DIR:-~/.claude/state/skill-active}/<name>.<session_id>, which
# analysis-page-gate.sh reads. The marker is written here, not in a parallel
# hook, so a denied call never leaves a marker behind.

set -uo pipefail

JQ=$(command -v jq) || exit 0
INPUT=$(cat) || exit 0
[ -n "$INPUT" ] || exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null) || exit 0
[ "$TOOL_NAME" = "Skill" ] || exit 0
SKILL=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.skill // empty' 2>/dev/null) || exit 0
[ -n "$SKILL" ] || exit 0
NAME=${SKILL##*:}
NAME=${NAME#/}
case "$NAME" in
    ''|*/*|.*) exit 0 ;;
esac

SESSION_ID=$(printf '%s' "$INPUT" | "$JQ" -r '.session_id // empty' 2>/dev/null) || SESSION_ID=""
MARK_DIR=${SKILL_MARKER_DIR:-$HOME/.claude/state/skill-active}
allow() {
    mkdir -p "$MARK_DIR" 2>/dev/null && touch "$MARK_DIR/$NAME.${SESSION_ID:-nosession}" 2>/dev/null
    exit 0
}

SKILLS_DIR=${FABLE_SKILLS_DIR:-$HOME/.claude/skills}
SKILL_MD="$SKILLS_DIR/$NAME/SKILL.md"
[ -r "$SKILL_MD" ] || allow
# Frontmatter only: lines between the first two `---`.
awk 'NR==1&&$0!="---"{exit} NR==1{next} $0=="---"{exit} {print}' "$SKILL_MD" \
    | grep -qE '^fable-spawn:[[:space:]]*true[[:space:]]*$' || allow

ARGS=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.args // empty' 2>/dev/null) || ARGS=""
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | "$JQ" -r '.transcript_path // empty' 2>/dev/null) || TRANSCRIPT_PATH=""
TOOL_USE_ID=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_use_id // empty' 2>/dev/null) || TOOL_USE_ID=""

MODEL=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -r "$TRANSCRIPT_PATH" ] && [ -n "$TOOL_USE_ID" ]; then
    MODEL=$(tail -n 2000 "$TRANSCRIPT_PATH" 2>/dev/null \
        | "$JQ" -R -c 'fromjson? // empty' \
        | "$JQ" -s -r --arg id "$TOOL_USE_ID" '
            [.[] | select(.type=="assistant")
                 | select([.message.content[]?.id?] | index($id))]
            | last
            | .message.model? // empty
          ' 2>/dev/null)
fi
MODEL_LC=$(printf '%s' "$MODEL" | tr '[:upper:]' '[:lower:]')

[ -n "$MODEL_LC" ] || allow
case "$MODEL_LC" in
    *fable*) allow ;;
esac

case "$NAME" in
    dream) RET="the PRD paths, lint result, review verdict lines" ;;
    *)     RET="the page path, lint result, review verdict lines, the weakest link and each mechanism with its state" ;;
esac

{
    echo "fable-skill-spawn-gate: /${NAME} runs on Fable max (SKILL.md fable-spawn: true); calling it inline from ${MODEL} switches this session's model and rebuilds its prompt cache."
    echo "Spawn it instead (one Agent call, the seat's cache stays warm):"
    echo "  Agent(subagent_type=general-purpose, model=fable, effort=max,"
    echo "        prompt=\"Invoke the ${NAME} skill (Skill tool, skill: ${NAME}, args: ${ARGS:-<args>}). Context + evidence: <paste>. Return ${RET}, and any finding for Joe, as one line each.\")"
    echo "Then log the result as a DECISION row as usual."
} >&2
exit 2
