#!/usr/bin/env bash
# park-fresh-fact.sh — PreToolUse hook (Bash, Edit, Write, MultiEdit): a park
# or block of a PRD must cite a fact newer than the slug's last commit.
# 10-08 11:47 pm a session parked two PRDs on a belief that a requeue commit
# (11:00 pm) had already falsified. A park must carry
# `because: run=<id>|decision=<id>|commit=<sha>`; the cited fact's time must
# not be older than any commit touching the slug in the last
# PARK_FRESH_WINDOW_MIN (default 60) minutes, else exit 2 naming that commit.
#
# Fails OPEN (exit 0, one `park-fresh-fact: cannot verify …` line) when the
# PRD repo, sqlite3, or the cited id is missing. PARK_FRESH_FACT=off bypasses.
# Env: PRD_DIR (~/Documents/PRDs), WM_STATE_DB (~/.local/state/wm-build/state.db).

set -uo pipefail

PRD_DIR="${PRD_DIR:-$HOME/Documents/PRDs}"
STATE_DB="${WM_STATE_DB:-$HOME/.local/state/wm-build/state.db}"
WINDOW_MIN="${PARK_FRESH_WINDOW_MIN:-60}"
AUDIT_FILE="${PARK_AUDIT_FILE:-$HOME/.cache/operator/park-audit.jsonl}"

JQ=$(command -v jq) || exit 0
INPUT=$(cat) || exit 0
[ -n "$INPUT" ] || exit 0

TOOL=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null) || exit 0

slug=""
text=""
case "$TOOL" in
    Bash)
        text=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.command // empty' 2>/dev/null) || exit 0
        if [[ $text =~ git[[:space:]]+mv[[:space:]]+[^[:space:]]*build-queue/PRD-([a-z0-9-]+)\.md[[:space:]]+[^[:space:]]*parked/ ]]; then
            slug="${BASH_REMATCH[1]}"
        elif [[ $text =~ requeue-prd\.sh[[:space:]].*--park[[:space:]]+([^[:space:]]+) ]]; then
            slug="${BASH_REMATCH[1]}"; slug="${slug#PRD-}"; slug="${slug%.md}"
        fi
        ;;
    Edit|Write|MultiEdit)
        fp=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0
        if [[ $fp =~ PRDs/.*/?PRD-([a-z0-9-]+)\.md$ ]]; then
            text=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input | [.new_string, .content, (.edits[]?.new_string)] | map(select(. != null)) | join("\n")' 2>/dev/null) || exit 0
            if printf '%s\n' "$text" | grep -qE '^- Status: (parked|blocked)'; then
                slug="${BASH_REMATCH[1]}"
            fi
        fi
        ;;
esac
[ -n "$slug" ] || exit 0

if [ "${PARK_FRESH_FACT:-}" = "off" ]; then
    echo "park-fresh-fact: bypassed (PARK_FRESH_FACT=off) for $slug"
    exit 0
fi

emit() { printf '%s\n' "$1"; printf '%s\n' "$1" >&2; }

if ! [[ $text =~ because:[[:space:]]*(run|decision|commit)=([A-Za-z0-9]+) ]]; then
    emit "PARK NEEDS because: run=<id>|decision=<id>|commit=<sha>  (park of $slug)"
    exit 2
fi
kind="${BASH_REMATCH[1]}"
id="${BASH_REMATCH[2]}"

cannot() { echo "park-fresh-fact: cannot verify $1"; exit 0; }

[ -d "$PRD_DIR/.git" ] || cannot "$PRD_DIR is not a git repo"
command -v sqlite3 >/dev/null 2>&1 || cannot "sqlite3 is not installed"
command -v git >/dev/null 2>&1 || cannot "git is not installed"

# Newest commit in the window touching the slug: its PRD file, or MANIFEST.md
# with the slug in the subject.
newest=$( {
    git -C "$PRD_DIR" log --since="$WINDOW_MIN minutes ago" --format='%h %ct %s' -- "*PRD-$slug.md" 2>/dev/null
    git -C "$PRD_DIR" log --since="$WINDOW_MIN minutes ago" --format='%h %ct %s' -- MANIFEST.md 2>/dev/null | grep -F -- "$slug"
  } | sort -k2,2nr | head -n1)

audit() { # $1=cite-fact-note
    mkdir -p "$(dirname "$AUDIT_FILE")" 2>/dev/null || return 0
    "$JQ" -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg slug "$slug" \
        --arg cite "$kind=$id" --arg nc "${newest%% *}" \
        '{ts:$ts,slug:$slug,cite:$cite,newest_commit:$nc}' >> "$AUDIT_FILE" 2>/dev/null || true
}

# Nothing touched the slug in the window: any cited fact is fresh enough.
if [ -z "$newest" ]; then audit; exit 0; fi

c_hash="${newest%% *}"; rest="${newest#* }"
c_time="${rest%% *}"; c_subj="${rest#* }"

fact_time=""
fact_desc=""
case "$kind" in
    run)
        [[ $id =~ ^[0-9]+$ ]] || cannot "run id '$id' is not numeric"
        row=$(sqlite3 -readonly "$STATE_DB" "select coalesce(nullif(ended,''), started) from runs where id=$id" 2>/dev/null) || cannot "state.db unreadable"
        [ -n "$row" ] || cannot "run $id not found"
        fact_time=$(date -d "$row" +%s 2>/dev/null) || cannot "run $id time '$row' unparseable"
        fact_desc="run $id's cause"
        ;;
    decision)
        [[ $id =~ ^[0-9]+$ ]] || cannot "decision id '$id' is not numeric"
        row=$(sqlite3 -readonly "$STATE_DB" "select opened from decisions where id=$id" 2>/dev/null) || cannot "state.db unreadable"
        [ -n "$row" ] || cannot "decision $id not found"
        fact_time=$(date -d "$row" +%s 2>/dev/null) || cannot "decision $id time '$row' unparseable"
        fact_desc="decision $id"
        ;;
    commit)
        fact_time=$(git -C "$PRD_DIR" show -s --format=%ct "$id" 2>/dev/null) || cannot "commit $id not found"
        if ! git -C "$PRD_DIR" diff-tree --no-commit-id --name-only -r "$id" 2>/dev/null | grep -qE "PRD-$slug\.md|MANIFEST\.md"; then
            emit "REFUSED: commit=$id does not touch $slug; cite a commit that does (newest: $c_hash $c_subj)"
            exit 2
        fi
        fact_desc="commit $id"
        ;;
esac

if [ "$c_time" -gt "$fact_time" ]; then
    when=$(date -d "@$c_time" '+%-I:%M %p')
    emit "REFUSED: $c_hash $when $c_subj is newer than $fact_desc; re-read it or cite commit=$c_hash"
    exit 2
fi

audit
exit 0
