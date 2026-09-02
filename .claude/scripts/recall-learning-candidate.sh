#!/usr/bin/env bash
# recall-learning-candidate.sh — Stop hook.
#
# Goal: nudge me toward `recall save` when this session contained a
# "learning moment" — user correction, surprising confirmation, or an
# explicit "save this" pattern I might have missed in the moment.
#
# Heuristic: scan the session JSONL for user turns containing learning
# pattern words. Score the matches with per-pattern weights; only emit
# a draft if the total score crosses THRESHOLD. De-duplicate within a
# session (one draft per session_id, even if the Stop hook fires twice).
# Every decision (emit / below_threshold / duplicate) appends one line
# to .audit.log so the prefilter is observable.
#
# Cradle stage: on top of the keyword-pattern loop, a second signal
# runs the `cradle` CLI's baked "redirect" classifier over (user_turn,
# prev_assistant) pairs built from the same window, to catch corrections
# that don't contain any of the literal pattern strings. It never blocks
# the hook: if `cradle` isn't on PATH the stage is skipped cleanly
# (audit cradle=absent); it's also wall-clock bounded (audit
# cradle=timeout if it runs out of budget mid-loop). Tunables:
#   CRADLE_P_MIN        min classifier probability to call a turn a
#                        "redirect" (default 0.9)
#   CRADLE_BUDGET_SECS   wall-clock budget for the whole stage, seconds
#                        (default 8)
#   WEIGHT_CRADLE        per-redirect-turn score weight (default 1.0),
#                        capped the same way pattern matches are
#                        (min(redirect_count, PER_PATTERN_CAP))
#
# Both the keyword pattern loop and the cradle turn-pair builder select
# user records through the same jq `is_human_prompt` filter (defined
# once, below, as JQ_HUMAN_PROMPT_DEF) so a real typed prompt is judged
# consistently and hook/task/system-injected content never counts as a
# "learning moment" in either stage.
#
# Best-effort; silent on every failure.
#
# Wired in settings.json:
#   Stop matcher="" → recall-learning-candidate.sh

set -uo pipefail
exec 2>/dev/null

# ---- Tunables (top-of-file per PRD-learning-candidate-prefilter AC7) ----
THRESHOLD=3                   # min score to emit a draft
PER_PATTERN_CAP=3             # cap a single pattern's match count contribution
WEIGHT_IMPERATIVE=2           # explicit "save this" / "always use" / etc.
WEIGHT_OBSERVATIONAL=1        # "actually no" / "i meant" / etc.
WEIGHT_CAPNOISE="0.5"         # high-volume but low-signal phrases
N=200                         # tail window over the session JSONL
CRADLE_P_MIN="${CRADLE_P_MIN:-0.9}"           # min p to call a turn "redirect"
CRADLE_BUDGET_SECS="${CRADLE_BUDGET_SECS:-8}" # wall-clock budget for the cradle stage
WEIGHT_CRADLE="${WEIGHT_CRADLE:-1.0}"         # per-redirect-turn score weight
# ------------------------------------------------------------------------

JQ=$(command -v jq || echo /usr/bin/jq)
[ -x "$JQ" ] || exit 0

input="$(cat)"
sid="$("$JQ" -r '.session_id // empty' <<<"$input")"
[ -n "$sid" ] || exit 0

# Locate the session JSONL. Same convention recall-stop uses.
sess_file="$HOME/.claude/projects/-home-jsy/$sid.jsonl"
[ -f "$sess_file" ] || exit 0

recent=$(tail -n "$N" "$sess_file")

draft_dir="${LEARNING_CANDIDATES_DIR:-$HOME/.claude/scratch/learning-candidates}"
audit_log="$draft_dir/.audit.log"
mkdir -p "$draft_dir"

# ---- Shared jq filter: "is this a real typed human prompt?" ------------
# A user record only counts (for the pattern loop AND the cradle stage)
# when .message.content is a string that isn't hook/task/system-injected
# noise. Defined once so the two stages cannot drift apart.
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

# ---- Pattern → weight table ---------------------------------------------
# bash associative arrays preserve insertion order for iteration on most
# implementations; we don't depend on order — the score is commutative.
declare -A pattern_weight=(
    ["save as feedback"]="$WEIGHT_IMPERATIVE"
    ["save this"]="$WEIGHT_IMPERATIVE"
    ["remember that"]="$WEIGHT_IMPERATIVE"
    ["remember this"]="$WEIGHT_IMPERATIVE"
    ["save to memory"]="$WEIGHT_IMPERATIVE"
    ["always use"]="$WEIGHT_IMPERATIVE"
    ["never use"]="$WEIGHT_IMPERATIVE"
    ["from now on"]="$WEIGHT_IMPERATIVE"
    ["never do"]="$WEIGHT_IMPERATIVE"
    ["stop doing"]="$WEIGHT_IMPERATIVE"
    ["don't do that"]="$WEIGHT_IMPERATIVE"
    ["you should always"]="$WEIGHT_IMPERATIVE"
    ["you should never"]="$WEIGHT_IMPERATIVE"
    ["actually no"]="$WEIGHT_OBSERVATIONAL"
    ["wait no"]="$WEIGHT_OBSERVATIONAL"
    ["correction"]="$WEIGHT_OBSERVATIONAL"
    ["i meant"]="$WEIGHT_OBSERVATIONAL"
    ["pairs with"]="$WEIGHT_OBSERVATIONAL"
    ["turns out"]="$WEIGHT_CAPNOISE"
)
# ------------------------------------------------------------------------

# Count matches across user messages. User .message.content has TWO
# shapes: string (typed prompts — what we count) or array of objects
# (tool_result responses — skip). is_human_prompt also drops injected
# noise (task-notifications, system-reminders, compaction summaries, …)
# that happens to arrive as a content string.
total_score="0"
matched_patterns=""
for p in "${!pattern_weight[@]}"; do
    n=$(printf '%s\n' "$recent" \
        | "$JQ" -r --arg p "$p" "$JQ_HUMAN_PROMPT_DEF"'
            select(.type=="user")
             | .message.content
             | select(is_human_prompt)
             | ascii_downcase
             | select(contains($p))' \
        2>/dev/null | wc -l)
    n=${n:-0}
    [ "$n" -gt 0 ] || continue
    capped=$n
    [ "$capped" -gt "$PER_PATTERN_CAP" ] && capped=$PER_PATTERN_CAP
    w="${pattern_weight[$p]}"
    contrib=$(awk -v w="$w" -v c="$capped" 'BEGIN{printf "%.2f", w*c}')
    total_score=$(awk -v a="$total_score" -v b="$contrib" 'BEGIN{printf "%.2f", a+b}')
    matched_patterns="$matched_patterns\n  - \"$p\" ($n, weight=$w)"
done

# ---- Cradle stage: model-scored redirects on top of keyword patterns ---
# Bounded, best-effort, never fatal. Builds (user_turn, prev_assistant)
# pairs from $recent in record order, classifies each with the compiled-in
# `redirect` model, and folds "high-confidence redirect" turns into the
# same score/matched_patterns/draft the pattern loop feeds.
cradle_status="ok"
n_pairs=0
n_redirect=0
redirect_list=()   # each element: "<p>\t<user_turn>"

if ! command -v cradle >/dev/null 2>&1; then
    cradle_status="absent"
else
    cradle_pairs_program="$JQ_HUMAN_PROMPT_DEF"'
        reduce .[] as $rec (
          {prev: "", pairs: []};
          if $rec.type == "assistant" then
            .prev = ([$rec.message.content[]? | select(.type=="text") | (.text // "")] | join(""))
          elif $rec.type == "user" and ($rec.message.content | is_human_prompt) then
            .pairs += [{
              user_turn: ($rec.message.content | .[0:2000]),
              prev_assistant: (.prev | .[0:2000])
            }]
          else
            .
          end
        )
        | .pairs[-40:][]
    '
    turn_pairs=$(printf '%s\n' "$recent" | "$JQ" -c -s "$cradle_pairs_program" 2>/dev/null)

    if [ -n "$turn_pairs" ]; then
        n_pairs=$(printf '%s\n' "$turn_pairs" | grep -c . 2>/dev/null)
        n_pairs=${n_pairs:-0}
    fi

    timed_out=0
    if [ "$n_pairs" -gt 0 ]; then
        SECONDS=0
        while IFS= read -r pair; do
            [ -n "$pair" ] || continue
            if [ "$SECONDS" -ge "$CRADLE_BUDGET_SECS" ]; then
                timed_out=1
                break
            fi
            cls_out=$(cradle classify redirect --turn-pair "$pair" --models-dir /nonexistent 2>/dev/null)
            [ $? -eq 0 ] || continue
            p=$("$JQ" -r '.p // empty' <<<"$cls_out" 2>/dev/null)
            [ -n "$p" ] || continue
            is_redirect=$(awk -v p="$p" -v m="$CRADLE_P_MIN" 'BEGIN{print (p+0 >= m+0) ? 1 : 0}')
            if [ "$is_redirect" -eq 1 ]; then
                n_redirect=$((n_redirect + 1))
                user_turn=$("$JQ" -r '.user_turn' <<<"$pair" 2>/dev/null)
                redirect_list+=("$p"$'\t'"$user_turn")
            fi
        done <<<"$turn_pairs"
    fi
    [ "$timed_out" -eq 1 ] && cradle_status="timeout"
fi

if [ "$n_redirect" -gt 0 ]; then
    capped_redirect=$n_redirect
    [ "$capped_redirect" -gt "$PER_PATTERN_CAP" ] && capped_redirect=$PER_PATTERN_CAP
    cradle_contrib=$(awk -v w="$WEIGHT_CRADLE" -v c="$capped_redirect" 'BEGIN{printf "%.2f", w*c}')
    total_score=$(awk -v a="$total_score" -v b="$cradle_contrib" 'BEGIN{printf "%.2f", a+b}')
    matched_patterns="$matched_patterns\n  - \"cradle:redirect\" ($n_redirect, weight=$WEIGHT_CRADLE, p>=$CRADLE_P_MIN)"
fi

case "$cradle_status" in
    absent)  cradle_audit_field="absent" ;;
    timeout) cradle_audit_field="timeout" ;;
    *)       cradle_audit_field="$n_pairs/$n_redirect" ;;
esac
# ------------------------------------------------------------------------

ts=$(date -u +%Y%m%dT%H%M%SZ)

# Score check (awk because score may be fractional, e.g. 1.5).
above_threshold=$(awk -v s="$total_score" -v t="$THRESHOLD" 'BEGIN{print (s+0 >= t+0) ? 1 : 0}')

# Count existing drafts for this session_id. Match on the header line
# that the current script (and this rewrite) emits unchanged.
dedup_count=0
if compgen -G "$draft_dir/*.md" >/dev/null 2>&1; then
    dedup_count=$(grep -lF "# Learning candidate — session $sid" "$draft_dir"/*.md 2>/dev/null | wc -l)
    dedup_count=${dedup_count:-0}
fi

decision=""
if [ "$above_threshold" -ne 1 ]; then
    decision="below_threshold"
elif [ "$dedup_count" -gt 0 ]; then
    decision="duplicate"
else
    decision="emit"
fi

# Audit every decision so the prefilter is observable.
printf '%s session=%s score=%s drafts_in_session=%s decision=%s cradle=%s\n' \
    "$ts" "$sid" "$total_score" "$dedup_count" "$decision" "$cradle_audit_field" \
    >> "$audit_log"

[ "$decision" = "emit" ] || exit 0

# --- Emit ---------------------------------------------------------------
draft_file="$draft_dir/$ts.md"

recent_prompts=$(printf '%s\n' "$recent" \
    | "$JQ" -r 'select(.type=="user") | .message.content | if type=="string" then . else empty end' \
    2>/dev/null | grep -v '^$' | tail -n 5)

# Up to 3 highest-confidence redirect turns, for the draft's own section.
redirect_section=""
if [ "$cradle_status" = "absent" ]; then
    redirect_section="cradle not on PATH; stage skipped."
elif [ "${#redirect_list[@]}" -gt 0 ]; then
    while IFS=$'\t' read -r rp rturn; do
        [ -n "$rp" ] || continue
        pf=$(awk -v x="$rp" 'BEGIN{printf "%.3f", x}')
        short=$(printf '%s' "$rturn" | cut -c1-120)
        redirect_section="$redirect_section\n- p=$pf · \"$short\""
    done < <(printf '%s\n' "${redirect_list[@]}" | sort -t $'\t' -k1,1 -rn | head -n 3)
else
    redirect_section="none scored >= $CRADLE_P_MIN across $n_pairs pairs"
fi

cat > "$draft_file" <<EOF
# Learning candidate — session $sid

**Detected:** $ts
**Score:** $total_score (threshold=$THRESHOLD, cap=$PER_PATTERN_CAP)
**Window:** last $N turns
**Matched patterns:**$(printf '%b' "$matched_patterns")

## Last 5 user prompts (context)

$(printf '%s\n' "$recent_prompts" | sed 's/^/> /')

## Redirect turns (cradle)

$(printf '%b' "$redirect_section")

## Suggested action

Review this session. If a durable rule, preference, or fact emerged,
\`recall save\` it as a feedback / user / project memory.

Delete this file (or move it to recall) once reviewed.
EOF

exit 0
