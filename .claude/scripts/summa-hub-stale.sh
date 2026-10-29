#!/usr/bin/env bash
# summa-hub-stale.sh — read-only freshness check for summa hub pages.
#
# A hub page is any $SUMMA_VAULT/wiki/**/*.md (entities/, playbooks/, any
# subdir) whose frontmatter `tags:` contains `hub`. Frontmatter parse (the
# first `---` .. `---` block only), line based, no YAML library:
#   tags:     inline `tags: [fleet, hub]` / `tags: [hub, fleet]` / `tags: hub`,
#             or a block list (`tags:` then `  - hub` lines). Quotes stripped,
#             match is the exact word `hub`.
#   sources:  inline `sources: [a, b]` or a block list (`sources:` then
#             `  - a` lines). Quotes stripped.
#   updated:  a date (2026-10-29: end of that day, LOCAL time) or a datetime
#             (2026-10-29T22:15:00Z). Unparseable or missing = stale.
#   title:    frontmatter `title:`, else the file basename.
#
# A `sources:` entry names the thing the page is a hub FOR (a subject, not a
# file), so globs are allowed. Resolution:
#   memory/<glob>   -> $SUMMA_MEMORY/<glob>
#   wiki/<glob>     -> $SUMMA_VAULT/wiki/<glob>   (wiki/goal.md, wiki/answers/*.md ..)
#   CLAUDE.md       -> $SUMMA_CLAUDE_MD
#   approvals.log   -> $HOME/.claude/state/approvals.log
#   anything else (or any `..`) is UNRESOLVABLE: the page is stale,
#   reason=unresolvable, never silently folded into no-match.
#
# A hub page is STALE when: `sources:` is missing/empty, OR an entry is
# unresolvable, OR no entry matches an existing file, OR `updated:` is older
# than the newest mtime across every matched file (or is unparseable).
#
# Output: one line per stale page
#   <title> updated=<ts> newest=<path>@<ts>
#   <title> updated=<ts> newest=none reason=<no-sources|no-match|no-updated>
#   <title> updated=<ts> newest=none reason=unresolvable entry=<entry>
# then exactly one last line `summa-hub-stale: stale=<n> of <m>` (m = hubs).
# Exit 0 on any completed scan (the count is the signal), 2 when the vault
# cannot be scanned. Never writes anything.
#
# Env: SUMMA_VAULT (default $HOME/Notes), SUMMA_MEMORY (default
# $HOME/.claude/projects/-home-jsy/memory), SUMMA_CLAUDE_MD (default
# $HOME/.claude/CLAUDE.md).

set -uo pipefail

SUMMA_VAULT="${SUMMA_VAULT:-$HOME/Notes}"
SUMMA_MEMORY="${SUMMA_MEMORY:-$HOME/.claude/projects/-home-jsy/memory}"
SUMMA_CLAUDE_MD="${SUMMA_CLAUDE_MD:-$HOME/.claude/CLAUDE.md}"
APPROVALS_LOG="$HOME/.claude/state/approvals.log"

wiki="$SUMMA_VAULT/wiki"
if [ ! -d "$wiki" ]; then
    echo "summa-hub-stale: vault wiki dir missing: $wiki" >&2
    exit 2
fi

iso() { date -d "@$1" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || echo "$1"; }

# Frontmatter -> "KEY<TAB>value" lines: T (title), U (updated), H (1 if hub tag), S (one per source).
fm_extract() {
    awk '
    function strip(s) {
        sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s)
        if (s ~ /^".*"$/ || s ~ /^\047.*\047$/) s = substr(s, 2, length(s) - 2)
        return s
    }
    function items(s, kind,    n, a, i, v) {
        s = strip(s)
        if (s ~ /^\[.*\]$/) s = substr(s, 2, length(s) - 2)
        n = split(s, a, ",")
        for (i = 1; i <= n; i++) {
            v = strip(a[i])
            if (v == "") continue
            if (kind == "tags") { if (v == "hub") print "H\t1" }
            else print "S\t" v
        }
    }
    NR == 1 { if ($0 != "---") exit; infm = 1; next }
    infm && $0 == "---" { exit }
    infm {
        if ($0 ~ /^[A-Za-z_][A-Za-z0-9_-]*:/) {
            key = $0; sub(/:.*/, "", key)
            val = $0; sub(/^[^:]*:[ \t]*/, "", val)
            blk = ""
            if (key == "title")   print "T\t" strip(val)
            else if (key == "updated") print "U\t" strip(val)
            else if (key == "tags" || key == "sources") {
                if (val == "") blk = key
                else items(val, key)
            }
            next
        }
        if (blk != "" && $0 ~ /^[ \t]*-[ \t]/) {
            v = $0; sub(/^[ \t]*-[ \t]+/, "", v)
            v = strip(v)
            if (v != "") { if (blk == "tags") { if (v == "hub") print "H\t1" } else print "S\t" v }
        }
    }
    ' "$1"
}

# resolve_entry <entry> -> prints matched file paths (one per line); returns 1 if the entry shape is unresolvable.
resolve_entry() {
    local e="$1" pat
    case "$e" in *..*) return 1 ;; esac
    case "$e" in
        memory/*) pat="$SUMMA_MEMORY/${e#memory/}" ;;
        wiki/*) pat="$SUMMA_VAULT/$e" ;;
        CLAUDE.md) pat="$SUMMA_CLAUDE_MD" ;;
        approvals.log) pat="$APPROVALS_LOG" ;;
        *) return 1 ;;
    esac
    local f
    # shellcheck disable=SC2086
    for f in $pat; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done
    return 0
}

stale=0
total=0

while IFS= read -r page; do
    meta="$(fm_extract "$page")"
    printf '%s\n' "$meta" | grep -q '^H	1$' || continue
    total=$((total + 1))

    title="$(printf '%s\n' "$meta" | awk -F'\t' '$1=="T"{print $2; exit}')"
    [ -n "$title" ] || title="$(basename "$page" .md)"
    upd_raw="$(printf '%s\n' "$meta" | awk -F'\t' '$1=="U"{print $2; exit}')"

    upd_epoch=""
    if [ -n "$upd_raw" ]; then
        if [[ "$upd_raw" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            upd_epoch="$(date -d "$upd_raw 23:59:59" +%s 2>/dev/null || true)"
        else
            upd_epoch="$(date -d "$upd_raw" +%s 2>/dev/null || true)"
        fi
    fi
    if [ -n "$upd_epoch" ]; then upd_show="$(iso "$upd_epoch")"; else upd_show="none"; fi

    mapfile -t sources < <(printf '%s\n' "$meta" | awk -F'\t' '$1=="S"{print $2}')
    if [ "${#sources[@]}" -eq 0 ]; then
        printf '%s updated=%s newest=none reason=no-sources\n' "$title" "$upd_show"
        stale=$((stale + 1))
        continue
    fi

    bad=""
    matched=()
    for e in "${sources[@]}"; do
        if ! out="$(resolve_entry "$e")"; then
            bad="$e"
            break
        fi
        while IFS= read -r m; do [ -n "$m" ] && matched+=("$m"); done <<<"$out"
    done
    if [ -n "$bad" ]; then
        printf '%s updated=%s newest=none reason=unresolvable entry=%s\n' "$title" "$upd_show" "$bad"
        stale=$((stale + 1))
        continue
    fi
    if [ "${#matched[@]}" -eq 0 ]; then
        printf '%s updated=%s newest=none reason=no-match\n' "$title" "$upd_show"
        stale=$((stale + 1))
        continue
    fi

    newest_line="$(stat -c '%Y %n' "${matched[@]}" | sort -k1,1nr | head -n1)"
    newest_epoch="${newest_line%% *}"
    newest_path="${newest_line#* }"

    if [ -z "$upd_epoch" ]; then
        printf '%s updated=none newest=%s@%s reason=no-updated\n' "$title" "$newest_path" "$(iso "$newest_epoch")"
        stale=$((stale + 1))
        continue
    fi
    if [ "$upd_epoch" -lt "$newest_epoch" ]; then
        printf '%s updated=%s newest=%s@%s\n' "$title" "$upd_show" "$newest_path" "$(iso "$newest_epoch")"
        stale=$((stale + 1))
    fi
# grep -w prefilter only skips files that cannot carry the tag; fm_extract decides.
done < <(grep -rlw --include='*.md' hub "$wiki" 2>/dev/null | sort)

printf 'summa-hub-stale: stale=%d of %d\n' "$stale" "$total"
exit 0
