#!/usr/bin/env bash
# prd-write-gate.sh — PreToolUse hook (Write, Bash): deny creating or
# overwriting a queued PRD (any `build-queue/PRD-*.md`) unless /dream is
# active in a live session. Joe, 2026-09-13: "make sure you never write
# another prd without /dream" — hand-filed PRDs skipped MANIFEST indexing
# and the failure / what-would-have-to-be-true checks; five of them were
# redrafted the same day.
#
# /dream is "active" when ~/.claude/.dream-active exists and is younger
# than DREAM_TTL_MIN. dream-marker.sh (PreToolUse Skill) touches it when
# the dream skill is invoked. Edit is deliberately NOT gated: /build's
# branch agents edit frontmatter (Status, Lane) in place, and the point is
# to stop creation-by-hand, not lifecycle edits. Fails OPEN on any parse
# error; a bug here must never block a live buildloop.
#
# Override (one-off, when Joe says so): touch ~/.claude/.allow-prd-handfile

set -uo pipefail

MARKER="${HOME}/.claude/.dream-active"
ALLOW_FLAG="${HOME}/.claude/.allow-prd-handfile"
DREAM_TTL_MIN="${DREAM_TTL_MIN:-180}"
LOG_FILE="${HOME}/.cache/prd-write-gate.log"

JQ=$(command -v jq) || exit 0
INPUT=$(cat) || exit 0
[ -n "$INPUT" ] || exit 0

TOOL=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null) || exit 0

deny() {
    printf '%s tool=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TOOL" "$2" >> "$LOG_FILE" 2>/dev/null
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
    exit 0
}

dream_active() {
    [ -f "$ALLOW_FLAG" ] && return 0
    [ -f "$MARKER" ] || return 1
    local age_min
    age_min=$(( ( $(date +%s) - $(stat -c %Y "$MARKER" 2>/dev/null || echo 0) ) / 60 ))
    [ "$age_min" -le "$DREAM_TTL_MIN" ]
}

REASON="PRD writes go through /dream (Joe 2026-09-13). Invoke the dream skill with the evidence as the seed; it drafts, indexes MANIFEST, and commits. One-off override only on Joe's say-so: touch ~/.claude/.allow-prd-handfile"

case "$TOOL" in
    Write)
        FP=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0
        case "$FP" in
            */build-queue/PRD-*.md)
                dream_active || deny "$REASON" "path=$FP"
                ;;
        esac
        ;;
    Bash)
        CMD=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.command // empty' 2>/dev/null) || exit 0
        # Creation-by-shell: a redirect, tee, cp, or install whose target is a
        # queued PRD. git mv / sed -i / git add on existing files pass through.
        if printf '%s' "$CMD" | grep -qE '(>>?|tee( -a)?|cp( -[a-zA-Z]+)*|install( -[a-zA-Z]+)*)[[:space:]]+[^[:space:]]*build-queue/PRD-[^[:space:]]*\.md'; then
            dream_active || deny "$REASON" "cmd=$(printf '%s' "$CMD" | head -c 120 | tr '\n' ' ')"
        fi
        ;;
esac

exit 0
