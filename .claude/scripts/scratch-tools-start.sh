#!/usr/bin/env bash
# scratch-tools-start.sh — SessionStart hook for stack + letter.
#
# Surfaces:
#   - pending stack (if non-empty)
#   - yesterday's letter (if present)
#
# Silent if both stack and letters are empty.

set -uo pipefail

STACK="${HOME}/.local/bin/stack"
LETTER="${HOME}/.local/bin/letter"

did_emit=0

# Stack
if [ -x "$STACK" ]; then
    out=$("$STACK" list 2>/dev/null)
    if [ -n "$out" ] && [ "$out" != "(empty)" ]; then
        printf '\n=== stack (pending intentions) ===\n'
        printf '%s\n' "$out"
        printf '=== /stack ===\n'
        did_emit=1
    fi
fi

# Yesterday's letter (or most recent)
if [ -x "$LETTER" ]; then
    out=$("$LETTER" show 2>/dev/null)
    if [ -n "$out" ]; then
        printf '\n=== letter from past-Claude ===\n'
        printf '%s\n' "$out"
        printf '=== /letter ===\n'
        did_emit=1
    fi
fi

exit 0
