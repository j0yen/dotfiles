#!/usr/bin/env bash
# agent-spawn-spec-lint.sh — PreToolUse hook (Agent): refuse a coder spawn
# whose cited spec carries unverified premises but whose prompt has no STEP 0.
#
# Rule: if the prompt CITES a spec file (a path matching \.spec\.md\b, or a
# path under /coders/ ending in .md) and that file contains the literal
# PREMISE-UNVERIFIED, the prompt must contain STEP 0 (case-insensitive;
# "STEP-0", "Step 0:" ok). Otherwise the spawn is denied with a reason naming
# the spec path, the count of PREMISE-UNVERIFIED lines and the fix.
# (rb eecb (c): a premise nobody verified must be verified or escalated by the
# coder before it acts, so the spawn prompt has to carry that step.)
#
# Decision shape (copied from block-expensive-spawn.sh / prd-write-gate.sh):
#   stdout {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#           "permissionDecision":"deny","permissionDecisionReason":"..."}}, exit 0
# Allow = exit 0 with no output.
#
# Fails OPEN on everything else (no jq, odd input, other tool, no spec cited,
# spec unreadable -> stderr NOTE). Reads only the cited specs (first 5
# distinct paths, 1 MB each). Never logs prompt contents anywhere; the only
# text emitted is the spec path and counts.
#
# --stanza   print the settings.json PreToolUse matcher group (not installed)
# --selftest run tests/agent-spawn-spec-lint.test.sh next to this hook's repo

set -uo pipefail

SELF=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
STANZA='{"matcher":"Agent","hooks":[{"type":"command","command":"/home/jsy/.claude/hooks/agent-spawn-spec-lint.sh","timeout":10}]}'
case "${1:-}" in
    --stanza) printf '%s\n' "$STANZA"; exit 0 ;;
    --selftest) exec bash "$(dirname "$SELF")/../../tests/agent-spawn-spec-lint.test.sh" ;;
esac

MAX_PATHS=5
MAX_BYTES=1048576
MARKER='PREMISE-UNVERIFIED'

JQ=$(command -v jq) || exit 0
INPUT=$(cat) || exit 0
[ -n "$INPUT" ] || exit 0

# one jq call: line 1 = tool_name, line 2 = cwd, rest = prompt
PARSED=$(printf '%s' "$INPUT" | "$JQ" -r '(.tool_name // ""), (.cwd // ""), (.tool_input.prompt // "")' 2>/dev/null) || exit 0
TOOL=${PARSED%%$'\n'*}
[ "$TOOL" = "Agent" ] || exit 0
REST=${PARSED#*$'\n'}
CWD=${REST%%$'\n'*}
PROMPT=${REST#*$'\n'}
[ -n "$PROMPT" ] || exit 0

# candidate .md tokens in the prompt, then keep spec-shaped ones
mapfile -t CANDS < <(printf '%s\n' "$PROMPT" | grep -oE "[^][:space:]\"'\`()<>,;:]+\.md\b" 2>/dev/null)
PATHS=()
for c in "${CANDS[@]}"; do
    case "$c" in
        *.spec.md | */coders/*.md) ;;
        *) continue ;;
    esac
    case "$c" in
        \~/*) c="${HOME}/${c#\~/}" ;;
        '$HOME/'*) c="${HOME}/${c#\$HOME/}" ;;
        '${HOME}/'*) c="${HOME}/${c#\$\{HOME\}/}" ;;
        /*) ;;
        *) [ -n "$CWD" ] && c="$CWD/$c" ;;
    esac
    dup=0
    for p in "${PATHS[@]}"; do [ "$p" = "$c" ] && dup=1 && break; done
    [ "$dup" = 1 ] && continue
    PATHS+=("$c")
    [ "${#PATHS[@]}" -ge "$MAX_PATHS" ] && break
done
[ "${#PATHS[@]}" -gt 0 ] || exit 0

HAS_STEP0=0
printf '%s' "$PROMPT" | grep -qiE '(^|[^[:alnum:]])step[ _-]?0([^0-9]|$)' && HAS_STEP0=1

OFFENDERS=""
for p in "${PATHS[@]}"; do
    if [ ! -f "$p" ] || [ ! -r "$p" ]; then
        printf 'agent-spawn-spec-lint NOTE: cited spec not readable, not linted: %s\n' "$p" >&2
        continue
    fi
    n=$(head -c "$MAX_BYTES" "$p" 2>/dev/null | grep -c -- "$MARKER") || n=0
    if [ "${n:-0}" -gt 0 ]; then
        OFFENDERS+="${OFFENDERS:+; }$p ($n $MARKER line(s))"
    fi
done

[ -n "$OFFENDERS" ] || exit 0
[ "$HAS_STEP0" = 1 ] && exit 0

REASON="Coder spawn refused: cited spec has unverified premises but the prompt has no STEP 0. Spec: ${OFFENDERS}. Fix: add a STEP 0 that verifies or escalates each ${MARKER} bullet before the coder acts, then spawn again."
"$JQ" -nc --arg r "$REASON" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
