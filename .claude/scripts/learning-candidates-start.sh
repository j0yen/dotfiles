#!/usr/bin/env bash
# learning-candidates-start.sh — SessionStart hook.
#
# Surfaces any pending learning-candidate drafts written by the Stop
# hook in prior sessions. These are nudges for me to `recall save`
# durable preferences I may have missed in the moment.
#
# Best-effort; silent if no candidates pending.

set -uo pipefail

draft_dir="$HOME/.claude/scratch/learning-candidates"
[ -d "$draft_dir" ] || exit 0

# Count and list (newest first) the pending candidates.
candidates=$(ls -t "$draft_dir"/*.md 2>/dev/null)
[ -n "$candidates" ] || exit 0

count=$(printf '%s\n' "$candidates" | wc -l)

printf '\n=== learning candidates: %s draft(s) awaiting review ===\n' "$count"
printf 'Stop hook flagged these sessions as having likely durable learnings.\n'
printf 'Review and either `recall write` a memory or delete the draft.\n\n'

# Show titles of up to 5 newest
i=0
while IFS= read -r f; do
    i=$((i+1))
    [ "$i" -gt 5 ] && break
    # Pull pattern matches from the file for a one-line summary
    patterns=$(grep -A20 "Matched patterns:" "$f" 2>/dev/null | grep -E '^\s*-' | head -3 | sed 's/^\s*//' | tr '\n' ' ')
    printf '  %s — %s\n' "$(basename "$f")" "$patterns"
done <<< "$candidates"

printf '\nAll drafts: %s\n' "$draft_dir"
printf '=== /learning candidates ===\n'

exit 0
