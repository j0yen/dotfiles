#!/usr/bin/env bash
# summa-candidates-start.sh — SessionStart hook (sync).
#
# Draft drain: a draft older than 7 days is deleted when its body is a status
# report (\bETA\b | still running | I don't know yet), else filed as
# $SUMMA_VAULT/wiki/answers/<draft-date>-<slug>.md with `status: unreviewed`
# (never overwrites: -2, -3, ...). Prints `drafts > 7 d: <n remaining>`.
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
SUMMA_VAULT="${SUMMA_VAULT:-$HOME/Notes}"
DRAIN_MIN=$((7 * 24 * 60))

printed_any=0

# ---- Draft drain -----------------------------------------------------------
yq() { # frontmatter value safe for `key: value`: quote when it holds ": " or a leading quote char
    local v="$1"
    case "$v" in
        \"*\") printf '%s' "$v"; return ;;
    esac
    case "$v" in
        *': '*|*'"'*|'#'*|'['*|'{'*) v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; printf '"%s"' "$v" ;;
        *) printf '%s' "$v" ;;
    esac
}
drain_draft() {
    local f="$1" body d today q asked slug dest n answers
    body="$(awk 'NR==1 && $0=="---"{fm=1;next} fm&&$0=="---"{fm=0;next} !fm{print}' "$f")"
    if printf '%s\n' "$body" | grep -qiE "\\bETA\\b|still running|I don'?t know yet"; then
        rm -f -- "$f"
        return
    fi
    answers="$SUMMA_VAULT/wiki/answers"
    [ -d "$SUMMA_VAULT/wiki" ] || return 0
    mkdir -p -- "$answers" 2>/dev/null || return 0
    d="$(date -r "$f" +%F)"
    today="$(date +%F)"
    q="$(grep -m1 '^question:' "$f" | sed -e 's/^question:[[:space:]]*//' -e 's/^"//' -e 's/"$//' -e 's/\\"/"/g')"
    asked="$(grep -m1 '^asked:' "$f" | sed -e 's/^asked:[[:space:]]*//')"
    [ -n "$asked" ] || asked="${d}T00:00:00Z"
    slug="$(printf '%s' "$q" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9' '-' | tr -s '-' | sed -e 's/^-//' -e 's/-$//' | cut -c1-60 | sed -e 's/-$//')"
    [ -n "$slug" ] || slug="draft-$(basename "$f" .md | cut -c1-8)"
    dest="$answers/$d-$slug.md"
    n=1
    while [ -e "$dest" ]; do
        n=$((n + 1))
        dest="$answers/$d-$slug-$n.md"
    done
    {
        printf -- '---\nsumma: answer\nquestion: %s\nasked: %s\ncites: []\nstatus: unreviewed\n---\n\n' "$(yq "$q")" "$asked"
        printf '> Filed %s from a session draft dated %s\n\n' "$today" "$d"
        printf '%s\n' "$body" | sed -e '/./,$!d'
    } >"$dest" && rm -f -- "$f"
}
if [ -d "$draft_dir" ]; then
    while IFS= read -r f; do
        [ -n "$f" ] && drain_draft "$f"
    done < <(find "$draft_dir" -maxdepth 1 -type f -name '*.md' -mmin +"$DRAIN_MIN" 2>/dev/null)
fi

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

old_n=0
if [ -d "$draft_dir" ]; then
    old_n="$(find "$draft_dir" -maxdepth 1 -type f -name '*.md' -mmin +"$DRAIN_MIN" 2>/dev/null | grep -c .)"
fi
printf 'drafts > 7 d: %s\n' "$old_n"

# 7-day read-after-inject line: per session the LAST read-after-inject row
# (Stop writes a cumulative row per turn), summed as read / injected.
JQ="${JQ:-jq}"
if command -v "$JQ" >/dev/null 2>&1; then
    cutoff="$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
    if [ -n "$cutoff" ] && [ -f "$SUMMA_LEDGER" ]; then
        summary="$("$JQ" -rs --arg cutoff "$cutoff" '
            map(select(.kind == "read-after-inject" and .ts >= $cutoff))
            | group_by(.sid) | map(last)
            | "read-after-inject 7d: \(map(.read) | add // 0)/\(map(.injected) | add // 0)"
        ' "$SUMMA_LEDGER" 2>/dev/null)"
        [ -n "$summary" ] && printf '%s\n' "$summary"
    fi
fi

exit 0
