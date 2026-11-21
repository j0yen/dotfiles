#!/usr/bin/env bash
# tests/fixtures/ledgerday/build-emit-tree.sh DIR — writes a deterministic
# transcript tree for ledgerday_ac9's output-equivalence case:
#   DIR/jsonl/...    TOKEN_LEDGER_JSONL_ROOT: every role path of file_role
#                    (inner, subagent verifier/coder/runner/review/scout,
#                    seat, aide main, aide lane with since=, top-level
#                    coder/interactive), compaction lines, and first user
#                    texts longer than 4001 chars whose whitespace runs
#                    straddle the 4001-codepoint chunk boundary of
#                    JQ_FIRST_TEXT's collapsed_head
#   DIR/seats.tsv    SEATS_TABLE
#   DIR/aide-sids    TOKEN_LEDGER_AIDE_SIDS
# emit-tree.golden.ndjson next to this script is the SORTED output of the
# pre-A1733 token-ledger (origin/main b5d981e, sha256 6bb58a042559113b)
# `--emit-local-records --since 2026-09-11T00:00:00Z` over this tree with
# TOKEN_LEDGER_LOCAL_HOST=carbon.
set -euo pipefail
d="$1"
J="$d/jsonl"
mkdir -p "$J/-home-jsy-proj/sid-parent/subagents" "$J/-home-jsy-wm-build-wt-x"

user() { # TEXT-or-JSON-content -> one user line; $2=uuid $3=ts
  jq -nc --argjson c "$1" --arg u "$2" --arg t "$3" '{type:"user", uuid:$u, timestamp:$t, message:{role:"user", content:$c}}'
}
utext() { user "$(jq -nc --arg s "$1" '$s')" "$2" "$3"; }
asst() { # id ts in cw cr out [model]
  jq -nc --arg id "$1" --arg ts "$2" --argjson i "$3" --argjson w "$4" --argjson r "$5" --argjson o "$6" --arg m "${7:-claude-opus-5-5}" \
    '{type:"assistant", timestamp:$ts, message:{id:$id, model:$m, usage:{input_tokens:$i, cache_creation_input_tokens:$w, cache_read_input_tokens:$r, output_tokens:$o}}}'
}
compact() { # uuid ts
  jq -nc --arg u "$1" --arg t "$2" '{type:"user", uuid:$u, timestamp:$t, isCompactSummary:true, message:{content:"This session is being continued from a previous conversation that ran out of context."}}'
}
# words "ab" joined by a 4-char whitespace run " \t\n ": each unit is 6 raw
# chars and 3 collapsed chars ("ab "); raw index 4000 (the last of the first
# 4001-codepoint chunk) falls inside unit 666's run
units() { local n="$1" k out=""; for ((k = 0; k < n; k++)); do out+=$'ab \t\n '; done; printf '%s' "$out"; }

f="$J/-home-jsy-proj/sid-parent/subagents"
{ utext "VERIFY the landed build" u-va 2026-09-11T01:00:00Z; asst m-va1 2026-09-11T01:00:05Z 10 20 300 4; } > "$f/agent-verify.jsonl"
{ utext "please implement the parser" u-co 2026-09-11T01:10:00Z; asst m-co1 2026-09-11T01:10:05Z 11 0 0 5; asst m-co1 2026-09-11T01:10:09Z 11 0 0 9; } > "$f/agent-coder.jsonl"
{ utext "RUNNER: go" u-ru 2026-09-11T01:20:00Z; asst m-ru1 2026-09-11T01:20:05Z 1 2 3 4; } > "$f/agent-runner.jsonl"
{ utext "re-grade this verdict" u-rv 2026-09-11T01:30:00Z; asst m-rv1 2026-09-11T01:30:05Z 2 0 0 1; } > "$f/agent-review.jsonl"
# 10000 whitespace chars, then the verifier keyword: collapses to " VERIFY ..." -> "VERIFY ..."
ws="$(printf '%*s' 5000 '' | sed 's/  / \n/g')"; ws="$ws$ws"
{ utext "${ws}VERIFY after a long blank prefix" u-wb 2026-09-11T01:40:00Z; asst m-wb1 2026-09-11T01:40:05Z 3 0 0 2; } > "$f/agent-blank-prefix.jsonl"
# "implement" at collapsed offsets 3991-3999, the last 9 chars .[0:4000] keeps -> coder
# (one extra space from an unmerged run at the chunk boundary would cut it)
{ utext "$(units 1330)ximplement the rest $(units 200)" u-in 2026-09-11T01:50:00Z; asst m-in1 2026-09-11T01:50:05Z 4 0 0 3; } > "$f/agent-keyword-inside.jsonl"
# "implement" at collapsed offset 3996: cut by .[0:4000] -> scout
{ utext "$(units 1332)implement the rest $(units 200)" u-cut 2026-09-11T02:00:00Z; asst m-cut1 2026-09-11T02:00:05Z 5 0 0 3; } > "$f/agent-keyword-cut.jsonl"
# first user line has a non-string text element AFTER a usable one (the whole line errors, as when every
# element went through gsub); the next user line decides -> runner
{ user '[{"type":"text","text":"implement x"},{"type":"text","text":null}]' u-ns 2026-09-11T02:10:00Z
  utext "run the suite" u-ns2 2026-09-11T02:10:01Z; asst m-ns1 2026-09-11T02:10:05Z 6 0 0 1; } > "$f/agent-nonstring.jsonl"
# harness-injected texts are skipped; the first real text in the array decides -> verifier
{ user '[{"type":"text","text":"<system-reminder>coder</system-reminder>"},{"type":"tool_result","content":"x"},{"type":"text","text":"  RE-VERIFY\n the merge"}]' u-hj 2026-09-11T02:20:00Z
  asst m-hj1 2026-09-11T02:20:05Z 7 0 0 1; } > "$f/agent-harness.jsonl"

p="$J/-home-jsy-proj"
{ utext "Read your full spec at /tmp/x" u-tc 2026-09-11T03:00:00Z; asst m-tc1 2026-09-11T03:00:05Z 100 200 3000 40; compact u-tc-c 2026-09-11T03:30:00Z; asst m-tc2 2026-09-11T03:40:00Z 1 0 0 1 claude-sonnet-5-5; } > "$p/sid-topcoder.jsonl"
{ user '"<command-name>/clear</command-name>"' u-ti0 2026-09-11T04:00:00Z; utext "hello there" u-ti 2026-09-11T04:00:01Z; asst m-ti1 2026-09-11T04:00:05Z 8 0 0 8; } > "$p/sid-interactive.jsonl"
# a long top-level first text whose coder keyword sits past collapsed offset 4000 -> interactive
{ utext "$(units 1400)Read your full spec" u-tl 2026-09-11T04:10:00Z; asst m-tl1 2026-09-11T04:10:05Z 9 0 0 9; } > "$p/sid-toplong.jsonl"
{ utext "seat tick" u-se 2026-09-11T05:00:00Z; asst m-se1 2026-09-11T05:00:05Z 50 0 0 5; } > "$p/sid-seat.jsonl"
{ utext "aide prompt" u-am 2026-09-11T06:00:00Z; asst m-am1 2026-09-11T06:00:05Z 60 0 0 6; } > "$p/sid-aidemain.jsonl"
# aide lane since 2026-09-11T12:00:00Z: the 11:00 record keeps the prior role (coder, by its text), the 13:00 one is the lane's
{ utext "implement lane work" u-al 2026-09-11T11:00:00Z; asst m-al1 2026-09-11T11:00:05Z 70 0 0 7; asst m-al2 2026-09-11T13:00:05.123Z 71 0 0 7; } > "$p/sid-lane.jsonl"
# a corrupt line mid-file: jq stops at it, so m-bad2 is never emitted (old and new alike)
{ utext "hello" u-bd 2026-09-11T07:00:00Z; asst m-bad1 2026-09-11T07:00:05Z 12 0 0 1; printf '{"type":"assistant", broken\n'; asst m-bad2 2026-09-11T07:00:09Z 13 0 0 1; } > "$p/sid-corrupt.jsonl"
{ utext "anything" u-wt 2026-09-11T08:00:00Z; asst m-wt1 2026-09-11T08:00:05Z 80 0 0 8; } > "$J/-home-jsy-wm-build-wt-x/inner.jsonl"

printf 'rb\topus\tsid-seat\n' > "$d/seats.tsv"
printf 'sid-aidemain\nsid-lane build since=%s\n' "$(date -u -d 2026-09-11T12:00:00Z +%s)" > "$d/aide-sids"
