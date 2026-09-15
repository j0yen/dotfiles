#!/usr/bin/env bash
# summa-candidates-start.sh — SessionStart hook (sync).
#
# Surfaces any pending answer-draft files written by
# summa-answer-candidate.sh (Stop hook) in prior sessions — these are
# candidate questions the wiki doesn't cover yet, worth `/summa ask`-ing
# for real. Also appends a 7-day hit/miss summary line to the ledger's
# banner so the lookup-hook's coverage is visible at a glance.
#
# Best-effort; silent if there is nothing to show.

set -uo pipefail

draft_dir="${SUMMA_ANSWER_CANDIDATES_DIR:-$HOME/.claude/scratch/summa-answer-candidates}"
SUMMA_LEDGER="${SUMMA_LEDGER:-$HOME/.cache/summa/lookups.jsonl}"

printed_any=0

if [ -d "$draft_dir" ] && compgen -G "$draft_dir"/*.md >/dev/null 2>&1; then
    candidates=$(ls -t "$draft_dir"/*.md 2>/dev/null)
    if [ -n "$candidates" ]; then
        count=$(printf '%s\n' "$candidates" | grep -c . || true)
        printf '=== summa: %s answer draft(s) awaiting review ===\n' "$count"
        i=0
        while IFS= read -r f; do
            i=$((i + 1))
            [ "$i" -gt 3 ] && break
            qline="$(grep -m1 '^question:' "$f" 2>/dev/null | sed -e 's/^question:[[:space:]]*//' -e 's/^"//' -e 's/"$//')"
            short="${qline:0:80}"
            printf '%s — %s\n' "$f" "$short"
        done <<<"$candidates"
        printf '=== /summa ===\n'
        printed_any=1
    fi
fi

# 7-day hit/miss summary line.
JQ="${JQ:-jq}"
if [ -f "$SUMMA_LEDGER" ] && command -v "$JQ" >/dev/null 2>&1; then
    cutoff="$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
    if [ -n "$cutoff" ]; then
        summary="$("$JQ" -rs --arg cutoff "$cutoff" '
            map(select(.ts >= $cutoff))
            | {h: (map(select(.result=="hit")) | length), m: (map(select(.result=="miss")) | length)}
            | "summa lookups last 7d: \(.h) hit / \(.m) miss"
        ' "$SUMMA_LEDGER" 2>/dev/null)"
        if [ -n "$summary" ]; then
            printf '%s\n' "$summary"
        fi
    fi
fi

exit 0
