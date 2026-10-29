#!/usr/bin/env bash
# summa-answer-candidate.sh — Stop hook (async).
#
# Goal: nudge me toward `/summa ask` when this session produced a real
# Q&A exchange that the summa wiki doesn't already cover — i.e. a
# question-shaped user prompt followed by a substantial assistant
# answer, where the wiki lookup hook (summa-lookup-inject.sh) recorded
# a miss for that same prompt in this session.
#
# Heuristic: scan the tail of the session JSONL for (user_prompt,
# next_assistant_text) pairs. A pair qualifies when:
#   - the prompt is question-shaped (ends with "?", or starts with one
#     of a fixed set of question words)
#   - prompt length >= 40
#   - assistant text length >= 400
#   - the prompt's sha256[:12] does NOT appear with "result":"hit" for
#     this session_id in SUMMA_LEDGER (a hit means the wiki already had
#     it — nothing new to file)
# Pick the pair with the longest assistant text.
#
# Selects real typed user prompts with the same JQ_HUMAN_PROMPT_DEF jq
# filter recall-learning-candidate.sh uses, so hook/task/system-injected
# content is never mistaken for a question the user actually asked.
#
# Dedupe: at most one draft per session_id (marker = existence of the
# draft file). Every decision (emit / below_threshold / duplicate /
# no_transcript) appends one line to .audit.log.
#
# Read-after-inject (every Stop, before the draft logic): for this session's
# ledger rows, how many of the pages summa-lookup-inject.sh actually injected
# (row field `injected`, vault-relative) did the session `Read`? Path match is
# `realpath -m` on both sides (symlinked vault paths compare equal). One row
# {"ts","sid","kind":"read-after-inject","read":n,"injected":m[,"bytes":b]} is
# appended to the ledger when the numbers changed since this sid's last such
# row (Stop fires every turn; the SessionStart line sums the LAST row per sid).
# `read` counts distinct injected paths with >= 1 Read call, so read <= injected.
#
# Best-effort; silent on every failure.

set -uo pipefail
exec 2>/dev/null

MIN_PROMPT_LEN=40
MIN_ANSWER_LEN=400
N=200 # tail window over the session JSONL

SUMMA_LEDGER="${SUMMA_LEDGER:-$HOME/.cache/summa/lookups.jsonl}"
SUMMA_VAULT="${SUMMA_VAULT:-$HOME/Notes}"
draft_dir="${SUMMA_ANSWER_CANDIDATES_DIR:-$HOME/.claude/scratch/summa-answer-candidates}"
audit_log="$draft_dir/.audit.log"
mkdir -p "$draft_dir" 2>/dev/null

JQ=$(command -v jq || echo /usr/bin/jq)
[ -x "$JQ" ] || exit 0

input="$(cat)"
sid="$("$JQ" -r '.session_id // empty' <<<"$input" 2>/dev/null)"
[ -n "$sid" ] || exit 0

ts="$(date -u +%Y%m%dT%H%M%SZ)"

# ---- Shared jq filter: "is this a real typed human prompt?" ------------
# (copied verbatim from recall-learning-candidate.sh so hook / task /
# system-injected content is never treated as a user prompt in either
# script.)
JQ_HUMAN_PROMPT_DEF='
def is_human_prompt:
  if type != "string" then false
  else
    (
      (startswith("<task-notification>")
        or startswith("<system-reminder>")
        or startswith("<command-name>")
        or startswith("<local-command")
        or contains("This session is being continued from a previous conversation")
        or contains("[SYSTEM NOTIFICATION"))
      | not
    )
  end;
'
# ------------------------------------------------------------------------

sess_file="$HOME/.claude/projects/-home-jsy/$sid.jsonl"

# ---- Read-after-inject ---------------------------------------------------
read_after_inject() {
    local tr="$1" inj_rel inj_abs="" p r
    [ -f "$SUMMA_LEDGER" ] && [ -f "$tr" ] || return 0
    inj_rel="$(grep -F "\"sid\":\"$sid\"" "$SUMMA_LEDGER" 2>/dev/null \
        | "$JQ" -r 'select(.kind == null) | (.injected // [])[]?' 2>/dev/null | sort -u)"
    [ -n "$inj_rel" ] || return 0
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        r="$(realpath -m -- "$SUMMA_VAULT/$p" 2>/dev/null)" || continue
        inj_abs="$inj_abs$r"$'\n'
    done <<<"$inj_rel"
    inj_abs="$(printf '%s' "$inj_abs" | sort -u)"
    local m
    m="$(printf '%s\n' "$inj_abs" | grep -c .)"
    [ "$m" -gt 0 ] || return 0

    # Every Read tool_use in the transcript: "<tool_use_id>\t<file_path>".
    local reads hit_ids="" read_paths="" id fp rp
    reads="$("$JQ" -r 'select(.type=="assistant") | .message.content[]?
        | select(type=="object" and .type=="tool_use" and .name=="Read" and (.input.file_path|type)=="string")
        | "\(.id)\t\(.input.file_path)"' "$tr" 2>/dev/null)"
    while IFS=$'\t' read -r id fp; do
        [ -n "$id" ] || continue
        rp="$(realpath -m -- "$fp" 2>/dev/null)" || continue
        if grep -qxF -- "$rp" <<<"$inj_abs"; then
            hit_ids="$hit_ids$id"$'\n'
            read_paths="$read_paths$rp"$'\n'
        fi
    done <<<"$reads"
    local n=0 ids_json bytes=""
    [ -n "$read_paths" ] && n="$(printf '%s' "$read_paths" | sort -u | grep -c .)"
    if [ -n "$hit_ids" ]; then
        ids_json="$(printf '%s' "$hit_ids" | "$JQ" -R . | "$JQ" -s . 2>/dev/null)"
        bytes="$("$JQ" -r --argjson ids "${ids_json:-[]}" 'select(.type=="user") | .message.content? | arrays | .[]
            | select(type=="object" and .type=="tool_result" and (.tool_use_id as $i | $ids | index($i)))
            | (.content | if type=="string" then . else ([.[]? | .text? // ""] | join("")) end | utf8bytelength)' "$tr" 2>/dev/null \
            | awk '{s += $1; c++} END {if (c) print s}')"
    fi
    local last row
    last="$(grep -F "\"sid\":\"$sid\"" "$SUMMA_LEDGER" 2>/dev/null | grep -F '"kind":"read-after-inject"' | tail -n1)"
    row="$("$JQ" -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sid "$sid" \
        --argjson read "$n" --argjson injected "$m" --arg bytes "$bytes" \
        '{ts:$ts, sid:$sid, kind:"read-after-inject", read:$read, injected:$injected}
         + (if $bytes != "" then {bytes:($bytes|tonumber)} else {} end)' 2>/dev/null)"
    [ -n "$row" ] || return 0
    if [ -n "$last" ] && [ "$("$JQ" -c 'del(.ts)' <<<"$last" 2>/dev/null)" = "$("$JQ" -c 'del(.ts)' <<<"$row" 2>/dev/null)" ]; then
        return 0
    fi
    printf '%s\n' "$row" >>"$SUMMA_LEDGER"
}
tr_path="$("$JQ" -r '.transcript_path // empty' <<<"$input" 2>/dev/null)"
[ -f "$tr_path" ] || tr_path="$sess_file"
read_after_inject "$tr_path"

if [ ! -f "$sess_file" ]; then
    printf '%s session=%s decision=no_transcript\n' "$ts" "$sid" >>"$audit_log"
    exit 0
fi

# Dedupe: one draft per session_id.
draft_file="$draft_dir/$sid.md"
if [ -e "$draft_file" ]; then
    printf '%s session=%s decision=duplicate\n' "$ts" "$sid" >>"$audit_log"
    exit 0
fi

recent=$(tail -n "$N" "$sess_file")

# JQ_HUMAN_PROMPT_DEF (above) already excludes <task-notification>,
# <system-reminder>, <command-name>, <local-command, and
# "[SYSTEM NOTIFICATION" — but NOT <cross-session-message (checked:
# recall's shared def doesn't carry that guard either), so it's added
# as an extra clause at the one call site below rather than forked
# into the copied def itself.
#
# Build (user_prompt, next_assistant_text) pairs in record order: a
# qualifying human user record opens a pending prompt; every assistant
# record's text blocks accumulate onto that prompt's answer until the
# next qualifying user record closes it (or the transcript tail ends,
# which is the common case — Stop fires right after the last answer).
pairs_program="$JQ_HUMAN_PROMPT_DEF"'
    (reduce .[] as $rec (
      {prompt: null, answer: "", pairs: []};
      if $rec.type == "user"
         and ($rec.message.content | is_human_prompt)
         and ($rec.message.content | (type != "string") or (contains("<cross-session-message") | not)) then
        (if .prompt != null then .pairs += [{prompt: .prompt, answer: .answer}] else . end)
        | .prompt = $rec.message.content
        | .answer = ""
      elif $rec.type == "assistant" then
        .answer += ([$rec.message.content[]? | select(.type=="text") | (.text // "")] | join(""))
      else
        .
      end
    )) as $acc
    | ($acc.pairs + (if $acc.prompt != null then [{prompt: $acc.prompt, answer: $acc.answer}] else [] end))
    | .[]
'

candidates="$(printf '%s\n' "$recent" | "$JQ" -c -s "$pairs_program" 2>/dev/null)"

best_prompt=""
best_answer=""
best_len=0

if [ -n "$candidates" ]; then
    while IFS= read -r pair; do
        [ -n "$pair" ] || continue
        prompt="$("$JQ" -r '.prompt' <<<"$pair" 2>/dev/null)"
        answer="$("$JQ" -r '.answer' <<<"$pair" 2>/dev/null)"
        [ -n "$prompt" ] || continue
        [ -n "$answer" ] || continue

        plen="${#prompt}"
        alen="${#answer}"
        [ "$plen" -ge "$MIN_PROMPT_LEN" ] || continue
        [ "$alen" -ge "$MIN_ANSWER_LEN" ] || continue

        # Question-shaped: ends with "?" OR first word is a question word.
        question_shaped=0
        case "$prompt" in
            *'?') question_shaped=1 ;;
        esac
        if [ "$question_shaped" -ne 1 ]; then
            first_word="$(printf '%s' "$prompt" | tr 'A-Z' 'a-z' | grep -oE '^[a-z]+' || true)"
            case "$first_word" in
                what|why|how|when|where|which|who|is|are|does|do|can|should|explain|compare)
                    question_shaped=1 ;;
            esac
        fi
        [ "$question_shaped" -eq 1 ] || continue

        # Already covered by the wiki? A "hit" in the ledger for this
        # session_id + prompt_sha means nothing new to file.
        prompt_sha="$(printf '%s' "$prompt" | sha256sum 2>/dev/null | cut -c1-12)"
        if [ -f "$SUMMA_LEDGER" ]; then
            already_hit="$("$JQ" -r --arg sid "$sid" --arg sha "$prompt_sha" \
                'select(.sid==$sid and .prompt_sha==$sha and .result=="hit") | .result' \
                "$SUMMA_LEDGER" 2>/dev/null | head -n1)"
            [ -z "$already_hit" ] || continue
        fi

        if [ "$alen" -gt "$best_len" ]; then
            best_len="$alen"
            best_prompt="$prompt"
            best_answer="$answer"
        fi
    done < <(printf '%s\n' "$candidates")
fi

if [ -z "$best_prompt" ]; then
    printf '%s session=%s decision=below_threshold\n' "$ts" "$sid" >>"$audit_log"
    exit 0
fi

# --- Emit ---------------------------------------------------------------
question_trunc="${best_prompt:0:300}"
answer_trunc="${best_answer:0:3000}"
asked="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# question line goes into YAML frontmatter — escape embedded quotes.
question_escaped="${question_trunc//\"/\\\"}"

cat > "$draft_file" <<EOF
---
summa: answer-draft
question: "$question_escaped"
asked: $asked
session_id: $sid
review: run /summa ask with this question, or delete this file
---

$answer_trunc
EOF

printf '%s session=%s decision=emit answer_len=%s\n' "$ts" "$sid" "$best_len" >>"$audit_log"

exit 0
