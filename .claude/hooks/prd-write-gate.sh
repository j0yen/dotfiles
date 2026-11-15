#!/usr/bin/env bash
# prd-write-gate.sh — PreToolUse hook (Write, Bash): deny creating or
# overwriting a queued PRD (any `build-queue/PRD-*.md`) unless /dream is
# active in THIS session. Joe, 2026-09-13: "make sure you never write
# another prd without /dream" — hand-filed PRDs skipped MANIFEST indexing
# and the failure / what-would-have-to-be-true checks; five of them were
# redrafted the same day.
#
# /dream is "active" for a session when its own per-session marker
# ${SKILL_MARKER_DIR:-~/.claude/state/skill-active}/dream-prd.<session_id>
# exists and is younger than DREAM_TTL_MIN. dream-marker.sh (PreToolUse
# Skill + UserPromptSubmit) writes it; this gate refreshes it only after a
# creation that marker admitted. A deny or an override admit creates and
# refreshes no marker; another session's marker, the sibling dream.<sid>
# (fable-skill-spawn-gate / skill-marker) and the legacy home-wide
# ~/.claude/.dream-active are never read (PRD dream-prd-marker-per-session:
# the home-wide file admitted every session in the home). An input with no
# session_id is denied. Edit is deliberately NOT gated: /build's branch
# agents edit frontmatter (Status, Lane) in place, and the point is to stop
# creation-by-hand, not lifecycle edits. Fails OPEN on any parse error; a
# bug here must never block a live buildloop. Trust limit: every session runs
# as the same Unix user and can touch its own marker; this guards against
# unintended cross-session admission, it is not a sandbox.
#
# Override (one-off, when Joe says so): touch ~/.claude/.allow-prd-handfile

set -uo pipefail

MARKER_DIR="${SKILL_MARKER_DIR:-$HOME/.claude/state/skill-active}"
ALLOW_FLAG="${HOME}/.claude/.allow-prd-handfile"
DREAM_TTL_MIN="${DREAM_TTL_MIN:-180}"
LOG_FILE="${HOME}/.cache/prd-write-gate.log"

JQ=$(command -v jq) || exit 0
INPUT=$(cat) || exit 0
[ -n "$INPUT" ] || exit 0

TOOL=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null) || exit 0
SID=$(printf '%s' "$INPUT" | "$JQ" -r '.session_id // empty' 2>/dev/null) || exit 0
OWN_MARKER="$MARKER_DIR/dream-prd.$SID"
ADMIT_BY=""
DENY_WHY=""

# deny <log detail> — the log records denies only, as before.
deny() {
    printf '%s tool=%s %s session=%s reason=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TOOL" "$1" "${SID:-missing}" "$DENY_WHY" >> "$LOG_FILE" 2>/dev/null
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s (reason: %s)"}}\n' "$REASON" "$DENY_WHY"
    exit 0
}

# dream_active — stats one path (this session's own marker) and checks the
# override; touches and creates nothing. Sets ADMIT_BY or DENY_WHY.
dream_active() {
    if [ -f "$ALLOW_FLAG" ]; then ADMIT_BY=override; return 0; fi
    if [ -z "$SID" ]; then DENY_WHY=no-session-id; return 1; fi
    if [ ! -f "$OWN_MARKER" ]; then DENY_WHY=marker-absent; return 1; fi
    local mtime age_min
    mtime=$(stat -c %Y "$OWN_MARKER" 2>/dev/null) || { DENY_WHY=marker-absent; return 1; }
    age_min=$(( ( $(date +%s) - mtime ) / 60 ))
    if [ "$age_min" -le "$DREAM_TTL_MIN" ]; then ADMIT_BY=marker; return 0; fi
    DENY_WHY=marker-stale
    return 1
}

REASON="PRD writes go through /dream (Joe 2026-09-13): invoke the dream skill in this session (Skill dream or a typed /dream); another session's /dream does not admit this one. It drafts, indexes MANIFEST, and commits. One-off override only on Joe's say-so: touch ~/.claude/.allow-prd-handfile"

# gate <log detail> — deny, or admit and refresh the own marker only when
# that marker admitted (never on an override admit, never on a deny).
gate() {
    dream_active || deny "$1"
    if [ "$ADMIT_BY" = marker ]; then touch -c "$OWN_MARKER" 2>/dev/null; fi
    return 0
}

case "$TOOL" in
    Write)
        FP=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0
        case "$FP" in
            */build-queue/PRD-*.md)
                gate "path=$FP"
                ;;
        esac
        ;;
    Bash)
        CMD=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.command // empty' 2>/dev/null) || exit 0
        # Creation-by-shell: a redirect, tee, cp, or install whose target is a
        # queued PRD. git mv / sed -i / git add on existing files pass through.
        if printf '%s' "$CMD" | grep -qE '(>>?|tee( -a)?|cp( -[a-zA-Z]+)*|install( -[a-zA-Z]+)*)[[:space:]]+[^[:space:]]*build-queue/PRD-[^[:space:]]*\.md'; then
            gate "cmd=$(printf '%s' "$CMD" | head -c 120 | tr '\n' ' ')"
        fi
        ;;
esac

exit 0
