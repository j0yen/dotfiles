#!/usr/bin/env bash
# analysis-page-gate.sh — PreToolUse (Write, Bash): a NEW analysis page in the
# vault is written only from inside its skill.
#
# Joe 2026-10-24 4:2x PM "make sure the new skill /5whysandrhyme is always used
# for analysis. never try to analyze it without the skill." + "what about the
# WWIT analysis for future features?"
#
#   ~/Notes/wiki/answers/*five-whys*   needs /5whysandrhyme
#   ~/Notes/wiki/decisions/*.md        needs /wwhtbt or /5whysandrhyme
#     (44 pages on 10-24, all plans/designs/records written by hand; a plan is
#     forward analysis, a failure decision comes out of a five-whys page)
#
# "From inside its skill" = BOTH:
#   1. a fresh marker ${SKILL_MARKER_DIR:-~/.claude/state/skill-active}/<skill>.<session_id>
#      (written by fable-skill-spawn-gate.sh on an allowed Skill call, or by
#      skill-marker.sh on a typed /<skill>), younger than SKILL_TTL_MIN (180);
#   2. the calling turn's model is Fable (both skills pin `model: fable`), so a
#      subagent's marker never lets its Opus parent write the page by hand.
#      Unknown model → marker alone decides.
# Editing an EXISTING page (amendments, status: reviewed) is always allowed.
# Bash: a command that names a not-yet-existing page path AND creates files
# (>, tee, mv, cp, install, rsync, open(…'w')) is treated as a create.

set -uo pipefail

JQ=$(command -v jq) || exit 0
INPUT=$(cat) || exit 0
[ -n "$INPUT" ] || exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null) || exit 0
SESSION_ID=$(printf '%s' "$INPUT" | "$JQ" -r '.session_id // empty' 2>/dev/null) || SESSION_ID=""
WIKI=${ANALYSIS_WIKI_DIR:-$HOME/Notes/wiki}
MARK_DIR=${SKILL_MARKER_DIR:-$HOME/.claude/state/skill-active}
TTL=${SKILL_TTL_MIN:-180}

# skill_for <abs path> → prints the required skill, or nothing.
skill_for() {
    case "$1" in
        "$WIKI"/answers/*five-whys*) echo 5whysandrhyme ;;
        "$WIKI"/decisions/*.md) echo "wwhtbt 5whysandrhyme" ;;
    esac
}

expand() {  # ~ and $HOME → absolute
    local p=$1
    case "$p" in
        '~/'*) p="$HOME/${p#\~/}" ;;
        '$HOME/'*|'${HOME}/'*) p="$HOME/${p#*/}" ;;
    esac
    printf '%s' "$p"
}

TARGETS=()
case "$TOOL_NAME" in
    Write)
        FP=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0
        [ -n "$FP" ] && [ ! -e "$FP" ] && TARGETS+=("$FP")
        ;;
    Bash)
        CMD=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.command // empty' 2>/dev/null) || exit 0
        case "$CMD" in *wiki/answers/*|*wiki/decisions/*) ;; *) exit 0 ;; esac
        # /dev/null and fd-dup redirects never create a page.
        WCMD=$(printf '%s' "$CMD" | sed -E 's/[0-9&]?>>?[[:space:]]*\/dev\/null//g; s/[0-9]>&[0-9]//g')
        printf '%s' "$WCMD" | grep -qE '>|\btee\b|\bmv\b|\bcp\b|\binstall\b|\brsync\b|open\([^)]*["'"'"'][wax]' || exit 0
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            case "$p" in *'*'*|*'?'*|*'['*) continue ;; esac   # a glob reads, never names a new page
            p=$(expand "$p")
            [ -e "$p" ] || TARGETS+=("$p")
        done < <(printf '%s' "$CMD" | grep -oE '[^[:space:]'"'"'"<>|;&()]*wiki/(answers|decisions)/[^[:space:]'"'"'"<>|;&)]+')
        ;;
    *) exit 0 ;;
esac
[ "${#TARGETS[@]}" -gt 0 ] || exit 0

MODEL=""
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | "$JQ" -r '.transcript_path // empty' 2>/dev/null) || TRANSCRIPT_PATH=""
TOOL_USE_ID=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_use_id // empty' 2>/dev/null) || TOOL_USE_ID=""
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

for t in "${TARGETS[@]}"; do
    need=$(skill_for "$t")
    [ -n "$need" ] || continue
    why="" fresh=""
    for k in $need; do
        [ -n "$(find "$MARK_DIR/$k.${SESSION_ID:-nosession}" -mmin -"$TTL" 2>/dev/null)" ] && fresh=$k
    done
    first=${need%% *}
    if [ -z "$fresh" ]; then
        why="no /${need// / or /} marker for this session in the last ${TTL} min"
    elif [ -n "$MODEL_LC" ] && [ "${MODEL_LC#*fable}" = "$MODEL_LC" ]; then
        why="the write comes from ${MODEL}, not the Fable turn running /$fresh"
    fi
    [ -n "$why" ] || continue
    {
        echo "analysis-page-gate: new page $t needs /${need// / or /} ($why)."
        echo "Joe 10-24: \"make sure the new skill /5whysandrhyme is always used for analysis. never try to analyze it without the skill.\""
        echo "Run the skill: type /$first, or from a non-Fable session spawn"
        echo "  Agent(subagent_type=general-purpose, model=fable, effort=max, prompt=\"Invoke the $first skill (Skill tool, skill: $first, args: <question>). Context + evidence: <paste>.\")"
        echo "Mitigate first; the skill never gates the same-sweep mitigation. Editing an existing page is allowed."
    } >&2
    exit 2
done
exit 0
