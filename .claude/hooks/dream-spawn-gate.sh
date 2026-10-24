#!/usr/bin/env bash
# dream-spawn-gate.sh — PreToolUse (Skill): a non-Fable turn that calls the
# dream skill is told to spawn a Fable subagent instead.
#
# /dream pins `model: fable` + `effort: max` (vibecode-kit#4, Joe 2026-10-24
# "make /dream use Fable Max"). Invoked inline from an Opus seat (rb/r7/ctl/
# aide), the pin switches the session model for that turn, and a model switch
# rebuilds the whole prompt cache. A subagent runs in its own context, so the
# seat's cache stays warm (Joe 2026-10-24 "can rb and r7 spawn a dream agent
# and avoid rebuilding the whole prompt cache?").
#
# Model detection is per CALL, same method as probe-gate.sh: find the
# transcript line whose assistant content holds this tool_use_id and read its
# model (a subagent's turns carry their own model). Fable → allow. Unknown →
# allow (fail open). Anything else → deny with the spawn recipe.
# A typed `/dream` is expanded by the harness without a Skill call, so Joe's
# own typed form is never gated. The subagent's Skill call still fires
# dream-marker.sh, so prd-write-gate.sh lets its PRD writes through.

set -uo pipefail

JQ=$(command -v jq) || exit 0
INPUT=$(cat) || exit 0
[ -n "$INPUT" ] || exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null) || exit 0
[ "$TOOL_NAME" = "Skill" ] || exit 0
SKILL=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.skill // empty' 2>/dev/null) || exit 0
case "$SKILL" in
    dream|*:dream) ;;
    *) exit 0 ;;
esac
ARGS=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.args // empty' 2>/dev/null) || ARGS=""

TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | "$JQ" -r '.transcript_path // empty' 2>/dev/null) || exit 0
TOOL_USE_ID=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_use_id // empty' 2>/dev/null) || exit 0

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

[ -n "$MODEL_LC" ] || exit 0
case "$MODEL_LC" in
    *fable*) exit 0 ;;
esac

{
    echo "dream-spawn-gate: /dream runs on Fable max; calling it inline from ${MODEL} switches this session's model and rebuilds its prompt cache."
    echo "Spawn it instead (one Agent call, the seat's cache stays warm):"
    echo "  Agent(subagent_type=general-purpose, model=fable, effort=max,"
    echo "        prompt=\"Invoke the dream skill (Skill tool, skill: dream, args: ${ARGS:-<args>}). Seed + evidence: <paste>. Return the PRD paths, lint result, review verdict lines, and any finding for Joe as one line each.\")"
    echo "Then log the persisted PRDs as a DECISION row as usual."
} >&2
exit 2
