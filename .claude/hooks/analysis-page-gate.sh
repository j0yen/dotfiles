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
# "From inside its skill" (A1300 E13 R6: the routing policy, not a SKILL.md pin, names the skill's model):
#   marker      a fresh ${SKILL_MARKER_DIR:-~/.claude/state/skill-active}/<skill>.<session_id> for a skill the
#               path needs (written by fable-skill-spawn-gate.sh on an allowed Skill call, or by skill-marker.sh
#               on a typed /<skill>), younger than SKILL_TTL_MIN (180).
#   turn model  the model of the assistant line that holds this call's tool_use_id, read from ONE transcript:
#               a subagent's call (the hook input carries agent_id) only in
#               <transcript_path without .jsonl>/subagents/agent-<agent_id>.jsonl, a main-thread call only in
#               transcript_path. Each read takes the last 2000 lines; the line can land after the hook starts,
#               so the file is re-read for up to 2 s before the model is called unknown.
#   launch row  the session's latest `launch` row in ${SKILL_ROUTING_DECISIONS:-~/.local/state/skill-routing/decisions.jsonl},
#               read with jq -R 'fromjson?' (a malformed line is skipped; an unreadable log means no row).
# Identity: in a session with a launch row, a turn whose model differs from the row's model is refused,
#   whichever rule would otherwise apply, and so is a turn whose model stays unknown.
# Routed rule: admitted with a fresh marker when the row has role author, a skill the path needs, reasons
#   containing "requested alternate" (fable-launch.sh writes reasons as one '; '-joined string) and a model
#   equal to the turn's.
# Today's rule: admitted with a fresh marker when the turn is Fable, in a session with no launch row or whose
#   row records no requested alternate. A session with no launch row keeps the marker-only fallback for an
#   unknown model; a model found in a subagent's transcript is judged like any other.
# SKILL_ROUTE_* environment variables are never read: the environment alone never admits.
# The hook decides within 4 s of its start (2 s re-read window, 4 s budget; fixed constants), under the
#   5 s timeout .claude/settings.json gives it.
# Editing an EXISTING page (amendments, status: reviewed) is always allowed.
# Bash: a command that names a not-yet-existing page path AND creates files
# (>, tee, mv, cp, install, rsync, open(…'w')) is treated as a create.

set -uo pipefail

now_us() { local t=${EPOCHREALTIME:-}; [ -n "$t" ] || t=$(date +%s%6N); printf '%s' "${t//[!0-9]/}"; }
T0=$(now_us)
readonly REREAD_US=2000000 BUDGET_US=4000000   # R6: the 2 s re-read window and the 4 s decision budget; no variable changes them

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

elapsed_us() { echo $(( $(now_us) - T0 )); }
# budget_left MARGIN_US: seconds (for timeout) left of the 4 s budget after MARGIN_US, or failure when none are left
budget_left() { local l=$(( BUDGET_US - $(elapsed_us) - $1 )); [ "$l" -gt 0 ] || return 1; printf '%d.%03d' $((l / 1000000)) $(((l % 1000000) / 1000)); }

fresh_for() {  # <needed skills> → the skill with a fresh marker for this session, or nothing
    local k fresh=""
    for k in $1; do
        [ -n "$(find "$MARK_DIR/$k.${SESSION_ID:-nosession}" -mmin -"$TTL" 2>/dev/null)" ] && fresh=$k
    done
    printf '%s' "$fresh"
}
ANY_FRESH=0
for t in "${TARGETS[@]}"; do
    need=$(skill_for "$t")
    [ -n "$need" ] && [ -n "$(fresh_for "$need")" ] && ANY_FRESH=1
done

# The session's latest launch row (R6), read before the transcript so the re-read window cannot starve it. Read only
# when a marker could admit; the environment is never consulted.
DEC_LOG=${SKILL_ROUTING_DECISIONS:-$HOME/.local/state/skill-routing/decisions.jsonl}
ROWJ="" LOG_LATE=0
if [ "$ANY_FRESH" = 1 ] && [ -n "$SESSION_ID" ] && [ -f "$DEC_LOG" ] && [ -r "$DEC_LOG" ]; then
    if left=$(budget_left 2500000); then
        ROWJ=$(timeout "$left" bash -c 'grep -F -- "$2" "$1" 2>/dev/null | "$3" -R -c --arg s "$2" "fromjson? | objects | select(.decision==\"launch\" and .session==\$s)" 2>/dev/null | tail -n 1' \
            _ "$DEC_LOG" "$SESSION_ID" "$JQ"); [ $? -ne 124 ] || { ROWJ=""; LOG_LATE=1; }
    else LOG_LATE=1; fi
fi
row_get() { printf '%s' "$ROWJ" | "$JQ" -r "$1" 2>/dev/null | head -n 1; }
if [ -n "$ROWJ" ]; then
    ROW_MODEL=$(row_get '.model | if type=="string" then . else "" end')
    ROW_ROLE=$(row_get '.role | if type=="string" then . else "" end')
    ROW_SKILL=$(row_get '.skill | if type=="string" then . else "" end')
    ROW_ALT=$(row_get '(.reasons | type) == "string" and (.reasons | contains("requested alternate"))')
fi

# The turn model, from the ONE transcript the hook input names (R6).
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | "$JQ" -r '.transcript_path // empty' 2>/dev/null) || TRANSCRIPT_PATH=""
TOOL_USE_ID=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_use_id // empty' 2>/dev/null) || TOOL_USE_ID=""
AGENT_ID=$(printf '%s' "$INPUT" | "$JQ" -r '.agent_id // empty' 2>/dev/null) || AGENT_ID=""
TR="" WHERE=main NOREAD=""
if [ -n "$AGENT_ID" ]; then
    WHERE=subagent
    if ! [[ "$AGENT_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then NOREAD="agent_id is not a plain id; no transcript read"
    elif [ -z "$TRANSCRIPT_PATH" ]; then NOREAD="the hook input names no transcript_path; no subagent transcript read"
    else TR="${TRANSCRIPT_PATH%.jsonl}/subagents/agent-${AGENT_ID}.jsonl"; fi
elif [ -z "$TRANSCRIPT_PATH" ]; then NOREAD="the hook input names no transcript_path; no transcript read"
else TR=$TRANSCRIPT_PATH; fi
[ -n "$NOREAD" ] || [ -n "$TOOL_USE_ID" ] || NOREAD="the hook input names no tool_use_id; the $WHERE transcript $TR was not searched"
MODEL_FILTER='[.[] | select(.type=="assistant") | select([.message.content[]?.id?] | index($id))] | last | .message.model? // empty'
model_once() {
    [ -z "$NOREAD" ] && [ -f "$TR" ] && [ -r "$TR" ] || return 0
    local left; left=$(budget_left 600000) || return 0
    timeout "$left" bash -c 'tail -n 2000 -- "$1" 2>/dev/null | grep -F -- "$2" | "$3" -R -c "fromjson? // empty" 2>/dev/null | "$3" -s -r --arg id "$2" "$4" 2>/dev/null' \
        _ "$TR" "$TOOL_USE_ID" "$JQ" "$MODEL_FILTER"
}
MODEL=$(model_once) REREAD=""
if [ -z "$MODEL" ] && [ "$ANY_FRESH" = 1 ] && [ -z "$NOREAD" ]; then
    REREAD=", re-read for up to 2 s"
    while [ -z "$MODEL" ] && [ "$(elapsed_us)" -lt "$REREAD_US" ]; do
        sleep 0.1
        MODEL=$(model_once)
    done
fi
MODEL_LC=$(printf '%s' "$MODEL" | tr '[:upper:]' '[:lower:]')
if [ -n "$MODEL" ]; then TURN="turn model: $MODEL (found in the $WHERE transcript $TR)"
elif [ -n "$NOREAD" ]; then TURN="turn model: unknown ($NOREAD)"
elif [ ! -f "$TR" ] || [ ! -r "$TR" ]; then TURN="turn model: unknown (the $WHERE transcript $TR does not exist or is unreadable)"
else TURN="turn model: unknown (tool_use $TOOL_USE_ID is not in the last 2000 lines of the $WHERE transcript $TR$REREAD)"; fi

for t in "${TARGETS[@]}"; do
    need=$(skill_for "$t")
    [ -n "$need" ] || continue
    why=""
    fresh=$(fresh_for "$need")
    first=${need%% *}
    if [ -z "$fresh" ]; then
        why="no /${need// / or /} marker for this session in the last ${TTL} min"
    elif [ "$LOG_LATE" = 1 ]; then
        why="the decisions log $DEC_LOG was not read within the hook's 4 s budget"
    elif [ -n "$ROWJ" ]; then
        if [ -z "$MODEL" ]; then
            why="the turn model is unknown, and this session has a launch row (role ${ROW_ROLE:-?}, /${ROW_SKILL:-?}, ${ROW_MODEL:-no model})"
        elif [ "$MODEL" != "$ROW_MODEL" ]; then
            why="the write comes from $MODEL, but this session's latest launch row records ${ROW_MODEL:-no model}"
        elif [ "$ROW_ROLE" = author ] && [ "$ROW_ALT" = true ] && [ -n "$ROW_SKILL" ] && [[ " $need " == *" $ROW_SKILL "* ]]; then
            :   # routed rule: the launcher-recorded author worker that asked for this alternate, on its launch model
        elif [ "$ROW_ALT" = true ]; then
            why="this session's latest launch row (role ${ROW_ROLE:-?}, /${ROW_SKILL:-?}, requested alternate on $ROW_MODEL) is not an author row of /${need// / or /}"
        elif [ "${MODEL_LC#*fable}" = "$MODEL_LC" ]; then
            why="the write comes from $MODEL, which is neither the Fable turn running /$fresh nor a requested alternate recorded by this session's launch row"
        fi
    elif [ -n "$MODEL_LC" ] && [ "${MODEL_LC#*fable}" = "$MODEL_LC" ]; then
        why="the write comes from ${MODEL}, not the Fable turn running /$fresh"
    fi
    [ -n "$why" ] || continue
    {
        echo "analysis-page-gate: new page $t needs /${need// / or /} ($why)."
        echo "$TURN"
        echo "Joe 10-24: \"make sure the new skill /5whysandrhyme is always used for analysis. never try to analyze it without the skill.\""
        echo "Run the skill through the managed launcher: ~/.local/bin/fable-launch.sh --route-request <request file> --session-id <pre-drawn id> -p \"Invoke the $first skill (Skill tool, skill: $first, args: <question>). Context + evidence: <paste>.\""
        echo "The routing policy picks the model; a non-Fable run names a listed alternate in requested.route with its model and effort, and only that launch's own turns, on the model its launch row records, write the page."
        echo "Mitigate first; the skill never gates the same-sweep mitigation. Editing an existing page is allowed."
    } >&2
    exit 2
done
exit 0
