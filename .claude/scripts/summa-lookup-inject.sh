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
stopwords="the this that with from what when where which does have about into your should would could there their they them then than also just like make need want some more only very been were will"

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

# ---- Answer lookup --------------------------------------------------------
# For each wiki/answers/*.md: frontmatter `question:` line (quotes stripped)
# plus the filename; count how many distinct keywords appear (case-insensitive
# substring). Rank by count desc, keep top 3 with count >=1.
answers_dir="$wiki_dir/answers"
answer_hits=""
answer_count=0
if [ -d "$answers_dir" ] && compgen -G "$answers_dir"/*.md >/dev/null 2>&1; then
    for f in "$answers_dir"/*.md; do
        base="$(basename "$f")"
        qline="$(grep -m1 '^question:' "$f" 2>/dev/null | sed -e 's/^question:[[:space:]]*//' -e 's/^"//' -e 's/"$//')"
        haystack="$(printf '%s %s' "$base" "$qline" | tr 'A-Z' 'a-z')"
        n=0
        for kw in "${kw_arr[@]}"; do
            case "$haystack" in
                *"$kw"*) n=$((n + 1)) ;;
            esac
        done
        [ "$n" -ge 1 ] || continue
        printf -v line '%d\t%s\t%s' "$n" "$base" "$qline"
        answer_hits="$answer_hits$line"$'\n'
    done
fi

top_answers=""
if [ -n "$answer_hits" ]; then
    top_answers="$(printf '%s' "$answer_hits" | sort -t $'\t' -k1,1 -rn | head -n 3)"
    answer_count="$(printf '%s\n' "$top_answers" | grep -c . || true)"
fi

# ---- Entity lookup ---------------------------------------------------------
# Names list from wiki/entities/*.md basenames (drop names <5 chars), then a
# whole-word fixed-string grep of each entity title inside the prompt.
entities_dir="$wiki_dir/entities"
entity_hits=""
entity_count=0
if [ -d "$entities_dir" ]; then
    names_file="$(mktemp)"
    trap 'rm -f "$names_file"' EXIT
    {
        for f in "$entities_dir"/*.md; do
            [ -e "$f" ] || continue
            name="${f##*/}"
            name="${name%.md}"
            [ "${#name}" -ge 5 ] || continue
            printf '%s\n' "$name"
        done
    } >"$names_file"
    if [ -s "$names_file" ]; then
        # grep -o returns the matched TEXT AS IT APPEARED IN THE PROMPT
        # (whatever case the user typed), not the pattern's original
        # case — so resolve each match back to its original-case
        # basename via a case-insensitive exact-line lookup in
        # names_file before using it to build a wiki path.
        matched_raw="$(grep -o -i -w -F -f "$names_file" <<<"$prompt" 2>/dev/null \
            | awk '!seen[tolower($0)]++' || true)"
        if [ -n "$matched_raw" ]; then
            resolved=""
            while IFS= read -r m; do
                [ -n "$m" ] || continue
                orig="$(grep -m1 -ixF "$m" "$names_file" 2>/dev/null)"
                [ -n "$orig" ] || orig="$m"
                resolved="$resolved$orig"$'\n'
            done <<<"$matched_raw"
            matched="$(printf '%s' "$resolved" | grep -v '^$' | awk '!seen[tolower($0)]++' || true)"
            if [ -n "$matched" ]; then
                entity_count="$(printf '%s\n' "$matched" | grep -c . || true)"
                top_entities="$(printf '%s\n' "$matched" | head -n 3)"
                entity_hits="$top_entities"
            fi
        fi
    fi
    rm -f "$names_file"
    trap - EXIT
fi

# ---- Build output ----------------------------------------------------------
pages=()
out=""
n_ans_out=0
if [ -n "$top_answers" ]; then
    while IFS=$'\t' read -r cnt base qline; do
        [ -n "$base" ] || continue
        short="${qline:0:100}"
        out="$out$(printf 'answer  wiki/answers/%s  — %s' "$base" "$short")"$'\n'
        pages+=("wiki/answers/$base")
        n_ans_out=$((n_ans_out + 1))
    done <<<"$top_answers"
fi

n_ent_out=0
if [ -n "$entity_hits" ]; then
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        out="$out$(printf 'entity  wiki/entities/%s.md' "$name")"$'\n'
        pages+=("wiki/entities/$name.md")
        n_ent_out=$((n_ent_out + 1))
    done <<<"$entity_hits"
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
[ "$hit_count" -ge 1 ] && result="hit"

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
    --arg mode "$mode" \
    --arg host "$host" \
    '{ts:$ts, sid:$sid, prompt_sha:$sha, keywords:$keywords, answers:$answers, entities:$entities, result:$result, pages:$pages, mode:$mode, host:$host}' \
    2>/dev/null)"

if [ -n "$line" ]; then
    printf '%s\n' "$line" >>"$SUMMA_LEDGER" 2>/dev/null || true
fi

exit 0
