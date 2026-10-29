#!/usr/bin/env bash
# summa-lookup-inject.sh — dual-mode hook.
#   Claude Code: UserPromptSubmit (sync, runs before Claude processes the
#     prompt). Plain-text stdout context block.
#   hermes (wintermute-agent, hub): pre_llm_call. hermes sends the
#     Claude Code wire shape but with the prompt at .extra.user_message
#     (not .prompt) and a .hook_event_name field; its context-injection
#     response must be JSON on stdout: {"context":"<text>"} — plain text
#     is ignored. hermes fires pre_llm_call on every LLM call inside one
#     turn, so hermes-mode dedupes per (session_id, prompt) so a single
#     turn logs/emits once even across repeated calls.
#
# Both modes: extracts keywords from the prompt and checks the summa
# wiki (~/Notes/wiki/{answers,entities}) for pages that already answer
# or name what's being asked, so the caller reads the page instead of
# re-deriving the answer from scratch.
#
# Ranker v2 (hub pages replace lookups): candidates are entities/, answers/
# and playbooks/ pages. A page qualifies only with >= 2 DISTINCT prompt
# keywords matched (token-prefix) on title + aliases + first paragraph, at
# least one of them on title/aliases/question (a paragraph-only overlap is
# noise: "reply single word" matched a hub on two prose words)
# (answers: the `question:` line is the title); only each page's frontmatter
# and first paragraph are read (capped at 4 KB). Pages tagged `hub` rank
# first, then match count. Mention-only stubs (body outside `## Mentions`
# < 200 bytes) are excluded, and a page is injected at most once per session
# (prior ledger rows with the same sid, last 2000 lines). The ledger row
# records `injected: [paths]` (what was actually emitted) so the Stop hook
# can score read-after-inject.
#
# Emits at most a 6-line context block (paths only, never page bodies) and
# appends one hit/miss line per evaluated prompt to a ledger (now also
# recording "mode" and "host" per line, so a fleet-wide ledger can be
# told apart by node/caller), so summa-lookups-report.sh can later show
# what the vault is missing.
#
# Wall-budget target: <300ms against the real vault (1394 entities).
# Skips short prompts and slash commands. Silent on every failure.

set -uo pipefail

SUMMA_VAULT="${SUMMA_VAULT:-$HOME/Notes}"
SUMMA_LEDGER="${SUMMA_LEDGER:-$HOME/.cache/summa/lookups.jsonl}"

wiki_dir="$SUMMA_VAULT/wiki"
[ -d "$wiki_dir" ] || exit 0

JQ="${JQ:-jq}"
command -v "$JQ" >/dev/null 2>&1 || exit 0

prompt=""
sid=""
mode="claude"
if [ ! -t 0 ]; then
    raw="$(cat -)"
    if [ -n "$raw" ]; then
        raw_prompt_field="$("$JQ" -r '.prompt // empty' <<<"$raw" 2>/dev/null || true)"
        hook_event_name="$("$JQ" -r '.hook_event_name // empty' <<<"$raw" 2>/dev/null || true)"
        # hermes mode: the wire payload carries .hook_event_name but no
        # top-level .prompt (its prompt lives at .extra.user_message).
        if [ -n "$hook_event_name" ] && [ -z "$raw_prompt_field" ]; then
            mode="hermes"
        fi
        prompt="$("$JQ" -r '.prompt // .extra.user_message // empty' <<<"$raw" 2>/dev/null || true)"
        sid="$("$JQ" -r '.session_id // empty' <<<"$raw" 2>/dev/null || true)"
    fi
fi

[ -n "$prompt" ] || exit 0

# Skip very short prompts — not enough signal
[ "${#prompt}" -ge 12 ] || exit 0

# Skip slash-command invocations
case "$prompt" in
    /*) exit 0 ;;
esac

# Skip harness-injected prompts — never real typed user input.
case "$prompt" in
    '<system-reminder>'*|*'[SYSTEM NOTIFICATION'*|*'<task-notification>'*|*'<cross-session-message'*) exit 0 ;;
esac

prompt_sha="$(printf '%s' "$prompt" | sha256sum 2>/dev/null | cut -c1-12)"

# hermes fires pre_llm_call once per LLM call inside a turn, and each
# call in that turn resends the same user_message — so if the LAST
# ledger line for this session_id already has this prompt_sha, this is
# a repeat call within the same turn: skip silently (no output, no new
# ledger line).
if [ "$mode" = "hermes" ] && [ -n "$sid" ] && [ -f "$SUMMA_LEDGER" ]; then
    last_for_sid="$(grep -F "\"sid\":\"$sid\"" "$SUMMA_LEDGER" 2>/dev/null | tail -n1)"
    if [ -n "$last_for_sid" ]; then
        last_sha="$("$JQ" -r '.prompt_sha // empty' <<<"$last_for_sid" 2>/dev/null || true)"
        [ "$last_sha" != "$prompt_sha" ] || exit 0
    fi
fi

# ---- Keyword extraction -------------------------------------------------
# Lowercase, split on non-alphanumerics, drop tokens <4 chars and a small
# stopword list, keep up to 6 distinct tokens in order of first appearance.
stopwords="the this that with from what when where which does have about into your should would could there their they them then than also just like make need want some more only very been were will seat event events wait lets status"

keywords="$(
    printf '%s' "$prompt" \
    | tr 'A-Z' 'a-z' \
    | tr -c 'a-z0-9' ' ' \
    | tr -s ' ' '\n' \
    | awk -v stop="$stopwords" '
        BEGIN {
            n = split(stop, sw, " ");
            for (i = 1; i <= n; i++) stopset[sw[i]] = 1;
        }
        {
            if (length($0) < 4) next;
            if ($0 in stopset) next;
            if ($0 ~ /^20[0-9][0-9]$/) next;
            if ($0 in seen) next;
            seen[$0] = 1;
            print $0;
            count++;
            if (count >= 6) exit;
        }
    '
)"

[ -n "$keywords" ] || exit 0

mapfile -t kw_arr <<<"$keywords"

# ---- Candidate scan (one awk over every candidate page) ---------------------
# Reads, per page, only the frontmatter (title / aliases / question / tags)
# and the first body paragraph, stopping at the paragraph end or 4096 bytes.
# Emits "<matches>\t<hub 0|1>\t<title matches>\t<path>\t<label>" for pages
# with >= 2 distinct keyword matches, >= 1 of them on title/aliases/question. A keyword matches a token that starts with it.
SCAN_AWK='
function lc(s) { return tolower(s) }
function flush(   hay, th, i, n, hits, thits, tok, t, ntok, parts) {
    if (cur == "") return
    hay = " " lc(title " " aliases " " question " " para) " "
    gsub(/[^a-z0-9]+/, " ", hay)
    th = " " lc(title " " aliases " " question) " "
    gsub(/[^a-z0-9]+/, " ", th)
    hits = 0; thits = 0
    for (i = 1; i <= nk; i++) {
        if (index(hay, " " kw[i]) > 0) hits++
        if (index(th, " " kw[i]) > 0) thits++
    }
    if (hits >= 2 && thits >= 1) {
        label = (question != "" ? question : title)
        gsub(/[\t\r]/, " ", label)
        printf "%d\t%d\t%d\t%s\t%s\n", hits, hub, thits, cur, substr(label, 1, 100)
    }
    cur = ""
}
function strip(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); if (s ~ /^".*"$/) s = substr(s, 2, length(s) - 2); return s }
BEGIN { nk = split(kws, kw, " ") }
FNR == 1 {
    flush()
    cur = FILENAME; infm = ($0 == "---"); done = 0; blk = ""
    title = ""; aliases = ""; question = ""; para = ""; hub = 0; bytes = 0; inpara = 0
    if (!infm) { done = 0 }
}
{
    if (cur == "") next
    bytes += length($0) + 1
    if (infm && FNR > 1) {
        if ($0 == "---") { infm = 0; next }
        if ($0 ~ /^[A-Za-z_][A-Za-z0-9_-]*:/) {
            k = $0; sub(/:.*/, "", k); v = $0; sub(/^[^:]*:[ \t]*/, "", v); blk = ""
            if (k == "title") title = strip(v)
            else if (k == "question") question = strip(v)
            else if (k == "aliases") { if (v == "") blk = "aliases"; else aliases = v }
            else if (k == "tags") { if (v == "") blk = "tags"; else if (v ~ /(^|[^a-z0-9_-])hub([^a-z0-9_-]|$)/) hub = 1 }
        } else if (blk != "" && $0 ~ /^[ \t]*-[ \t]/) {
            v = $0; sub(/^[ \t]*-[ \t]+/, "", v)
            if (blk == "aliases") aliases = aliases " " v
            else if (strip(v) == "hub") hub = 1
        }
        if (bytes > 4096) { flush(); nextfile }
        next
    }
    if (FNR == 1 && infm) next
    if (!done) {
        if ($0 ~ /^[ \t]*$/ || $0 ~ /^#/) { if (inpara) { done = 1 } }
        else { para = para " " $0; inpara = 1 }
        if (done || bytes > 4096) { flush(); nextfile }
    }
}
END { flush() }
'

scan_dirs=()
for d in entities answers playbooks; do
    [ -d "$wiki_dir/$d" ] && scan_dirs+=("$wiki_dir/$d")
done
candidates=""
if [ "${#scan_dirs[@]}" -gt 0 ]; then
    candidates="$(find "${scan_dirs[@]}" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null \
        | xargs -0 awk -v kws="${kw_arr[*]}" "$SCAN_AWK" 2>/dev/null \
        | sort -t $'\t' -k2,2nr -k1,1nr -k3,3nr -k4,4 )"
fi

# Pages already injected earlier in this session (cheap: tail window + grep).
prior_injected=""
if [ -n "$sid" ] && [ -f "$SUMMA_LEDGER" ]; then
    prior_injected="$(tail -n 2000 "$SUMMA_LEDGER" 2>/dev/null | grep -F "\"sid\":\"$sid\"" \
        | "$JQ" -r '(.injected // .pages // [])[]?' 2>/dev/null | sort -u)"
fi

# Body bytes outside a `## Mentions` section (frontmatter excluded).
body_bytes_outside_mentions() {
    awk '
        NR == 1 && $0 == "---" { fm = 1; next }
        fm { if ($0 == "---") fm = 0; next }
        /^## / { skip = ($0 ~ /^## Mentions[ \t]*$/) }
        !skip { n += length($0) + 1 }
        END { print n + 0 }
    ' "$1" 2>/dev/null
}

# ---- Build output ----------------------------------------------------------
pages=()
out=""
n_ans_out=0
n_ent_out=0
matched_any=0
n_dedup=0
n_ans_slot=0
n_ent_slot=0
if [ -n "$candidates" ]; then
    while IFS=$'\t' read -r cnt is_hub tcnt path label; do
        [ -n "$path" ] || continue
        rel="wiki/${path#"$wiki_dir"/}"
        if [ "$is_hub" != "1" ]; then
            [ "$(body_bytes_outside_mentions "$path")" -ge 200 ] || continue
        fi
        matched_any=1
        # The caps pick the top pages first; a page already injected this
        # session then drops out WITHOUT back-filling from lower ranks.
        case "$rel" in
            wiki/answers/*) [ "$n_ans_slot" -lt 3 ] || continue; n_ans_slot=$((n_ans_slot + 1)) ;;
            *) [ "$n_ent_slot" -lt 3 ] || continue; n_ent_slot=$((n_ent_slot + 1)) ;;
        esac
        if [ -n "$prior_injected" ] && grep -qxF -- "$rel" <<<"$prior_injected"; then
            n_dedup=$((n_dedup + 1))
            continue
        fi
        case "$rel" in
            wiki/answers/*)
                out="$out$(printf 'answer  %s  — %s' "$rel" "${label:0:100}")"$'\n'
                n_ans_out=$((n_ans_out + 1)) ;;
            wiki/entities/*)
                out="$out$(printf 'entity  %s' "$rel")"$'\n'
                n_ent_out=$((n_ent_out + 1)) ;;
            *)
                out="$out$(printf 'page    %s' "$rel")"$'\n'
                n_ent_out=$((n_ent_out + 1)) ;;
        esac
        pages+=("$rel")
    done <<<"$candidates"
fi

hit_count=$((n_ans_out + n_ent_out))

if [ "$hit_count" -ge 1 ]; then
    # Capture the exact same block text for both modes ($(...) strips
    # only the trailing newline; re-added below so Claude Code mode
    # stays byte-identical to before this dual-mode change).
    block="$(printf '=== summa: wiki pages for this prompt (read before re-deriving) ===\n%s=== /summa ===\n' "$out")"
    if [ "$mode" = "hermes" ]; then
        "$JQ" -n --arg c "$block" '{context:$c}' 2>/dev/null
    else
        printf '%s\n' "$block"
    fi
fi
# hermes: nothing on stdout on a miss (never {}). Claude Code: same —
# no output on a miss, as before.

# ---- Ledger --------------------------------------------------------------
# One JSON line per evaluated prompt (hit or miss), built with jq for safe
# quoting. Single printf >> append. Records mode + host so a fleet-wide
# ledger can tell node/caller apart.
mkdir -p "$(dirname "$SUMMA_LEDGER")" 2>/dev/null || true

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
result="miss"
{ [ "$hit_count" -ge 1 ] || [ "$matched_any" -eq 1 ]; } && result="hit"

kw_json="$(printf '%s\n' "${kw_arr[@]}" | "$JQ" -R . | "$JQ" -s . 2>/dev/null)"
pages_json="[]"
if [ "${#pages[@]}" -gt 0 ]; then
    pages_json="$(printf '%s\n' "${pages[@]}" | "$JQ" -R . | "$JQ" -s . 2>/dev/null)"
fi

line="$("$JQ" -nc \
    --arg ts "$ts" \
    --arg sid "$sid" \
    --arg sha "$prompt_sha" \
    --argjson keywords "${kw_json:-[]}" \
    --argjson answers "$n_ans_out" \
    --argjson entities "$n_ent_out" \
    --arg result "$result" \
    --argjson pages "${pages_json:-[]}" \
    --argjson injected "${pages_json:-[]}" \
    --argjson deduped "$n_dedup" \
    --arg mode "$mode" \
    --arg host "$host" \
    '{ts:$ts, sid:$sid, prompt_sha:$sha, keywords:$keywords, answers:$answers, entities:$entities, result:$result, pages:$pages, injected:$injected, deduped:$deduped, mode:$mode, host:$host}' \
    2>/dev/null)"

if [ -n "$line" ]; then
    printf '%s\n' "$line" >>"$SUMMA_LEDGER" 2>/dev/null || true
fi

exit 0
