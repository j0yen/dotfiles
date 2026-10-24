#!/usr/bin/env bash
# analysis-skill-router.sh: explicit phrases point at the skill and log; plain prompts silent; wired.
set -u
H="$(dirname "$0")/../.claude/hooks/analysis-skill-router.sh"; S="$(dirname "$0")/../.claude/settings.json"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export ANALYSIS_ROUTER_LOG="$T/log.jsonl"
fail=0
r(){ jq -nc --arg p "$1" '{prompt:$p,session_id:"s1"}' | "$H"; }
want(){ out=$(r "$2"); case "$3" in
  none) [ -z "$out" ] && echo "ok $1" || { echo "FAIL $1: $out"; fail=1; } ;;
  *) printf '%s' "$out" | grep -q "run /$3 " && echo "ok $1" || { echo "FAIL $1: '$out'"; fail=1; } ;; esac; }
want "five whys"    "do a five whys on the 1055 stall" 5whysandrhyme
want "5 whys"       "5 Whys please" 5whysandrhyme
want "and rhyme"    "5 whys and rhyme for redbaron" 5whysandrhyme
want "root cause"   "what's the root cause of the freeze?" 5whysandrhyme
want "postmortem"   "write a post-mortem" 5whysandrhyme
want "wwit"         "what about the WWIT analysis for future features?" wwhtbt
want "what would"   "what would have to be true for one-url onboarding" wwhtbt
want "plain why"    "why is the build slow?" none
want "plain status" "STATUS" none
want "typed skill"  "/5whysandrhyme five whys on X" none
[ "$(wc -l <"$T/log.jsonl")" = 7 ] && echo "ok 7 fires logged" || { echo "FAIL log lines $(wc -l <"$T/log.jsonl")"; fail=1; }
jq -e '.hooks.UserPromptSubmit[] | .hooks[] | select(.command|endswith("analysis-skill-router.sh"))' "$S" >/dev/null \
  && echo "ok wired" || { echo "FAIL not wired"; fail=1; }
exit $fail
