#!/usr/bin/env bash
# skill-agent-effort-guard.test.sh: PreToolUse(Agent) guard for the 5whysandrhyme/wwhtbt workflows (ledger A1159).
# Fake Agent records only; no provider call. Run alone: bash tests/skill-agent-effort-guard.test.sh
set -u
R="$(cd "$(dirname "$0")/.." && pwd)"
G="$R/.claude/hooks/skill-agent-effort-guard.sh"
export SKILL_POLICY_LIB="$R/.local/lib/skill-model-policy.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export MEA_MAX_EXCEPTION="$T/exc.json" MEA_OPEN_ASKS="$T/asks.tsv"
printf 'A9001\t2026-11-06\tctl\tx\n' >"$T/asks.tsv"
fail=0
rec(){ jq -cn --arg m "$1" --arg e "$2" --arg p "$3" --arg t "${4:-Agent}" '{tool_name:$t,tool_input:({prompt:$p,subagent_type:"general-purpose"}
        + (if $m=="" then {} else {model:$m} end) + (if $e=="" then {} else {effort:$e} end))}'; }
chk(){ # name want model effort prompt [tool]
  rec "$3" "$4" "$5" "${6:-Agent}" | "$G" >/dev/null 2>"$T/err"; rc=$?
  [ "$rc" = "$2" ] && echo "ok $1" || { echo "FAIL $1 rc=$rc want $2: $(cat "$T/err")"; fail=1; }; }
S5='Invoke the 5whysandrhyme skill (Skill tool, skill: 5whysandrhyme, args: stoppage). Return the page path.'
SW='Run the wwhtbt skill on plan X and file the page.'
RV='Independent review of the 5whysandrhyme page ~/Notes/wiki/answers/x.md: return verdict lines.'
chk "5whys fable/xhigh allowed" 0 fable xhigh "$S5"
chk "5whys full model id allowed" 0 claude-fable-5-1 xhigh "$S5"
chk "wwhtbt fable/xhigh allowed" 0 fable xhigh "$SW"
chk "independent review fable/xhigh allowed" 0 fable xhigh "$RV"
chk "5whys effort missing (inherited) rejected" 2 fable "" "$S5"
chk "5whys model missing (inherited) rejected" 2 "" xhigh "$S5"
chk "5whys both missing rejected" 2 "" "" "$S5"
chk "5whys high rejected" 2 fable high "$S5"
chk "wwhtbt medium rejected" 2 fable medium "$SW"
chk "5whys max rejected without exception" 2 fable max "$S5"
chk "review high rejected" 2 fable high "$RV"
chk "review on sonnet rejected" 2 sonnet xhigh "$RV"
chk "wwhtbt on opus rejected" 2 opus xhigh "$SW"
chk "slash form rejected when wrong" 2 fable high "please run /wwhtbt on the plan"
chk "fable spawn naming the skill rejected when high" 2 fable high "summarise the wwhtbt page for Joe"
# max exception: ledger-backed
exc(){ jq -cn --arg s "$1" --arg l "$2" --arg g "$3" --arg x "$4" '{skill:$s,ledger:$l,gap:$g,expires:$x}' >"$MEA_MAX_EXCEPTION"; }
fut=$(date -d '+1 hour' +%Y-%m-%dT%H:%M:%S%z); past=$(date -d '-1 hour' +%Y-%m-%dT%H:%M:%S%z)
exc 5whysandrhyme A9001 "unresolved gap in why 3" "$fut"; chk "max allowed with valid exception" 0 fable max "$S5"
chk "max exception for another skill rejected" 2 fable max "$SW"
exc "*" A9001 "gap" "$fut";                              chk "wildcard exception allows max" 0 fable max "$SW"
exc 5whysandrhyme A9001 "gap" "$past";                  chk "expired exception rejected" 2 fable max "$S5"
exc 5whysandrhyme A7777 "gap" "$fut";                   chk "exception ledger row absent rejected" 2 fable max "$S5"
exc 5whysandrhyme A9001 "" "$fut";                      chk "exception without gap rejected" 2 fable max "$S5"
exc 5whysandrhyme A9001 "gap" "$fut";                   chk "exception does not excuse high" 2 fable high "$S5"
chk "exception does not excuse sonnet/max" 2 sonnet max "$S5"
rm -f "$MEA_MAX_EXCEPTION"
# unaffected surfaces
chk "dream keeps its own max" 0 fable max "Invoke the dream skill on seed Z"
chk "dream with no effort untouched" 0 "" "" "Run /dream amend slug-1"
chk "ordinary coder spawn unchanged" 0 sonnet medium "Implement the parser from the spec"
chk "ordinary fable review (no skill) unchanged" 0 fable high "Review this PRD draft and return a verdict line"
chk "haiku scout naming the page unchanged" 0 haiku "" "find the wwhtbt page path under ~/Notes"
chk "non-Agent tool ignored" 0 "" "" "$S5" Bash
echo '{"tool_name":"Agent"' | "$G" >/dev/null 2>&1 && echo "ok malformed input fails open" || { echo "FAIL malformed input"; fail=1; }
# policy lib missing (guard copied away from the repo lib): covered skill fails closed, others pass
mkdir -p "$T/iso/.claude/hooks"; cp "$G" "$T/iso/.claude/hooks/"; IG="$T/iso/.claude/hooks/skill-agent-effort-guard.sh"
rec fable xhigh "$S5" | SKILL_POLICY_LIB=/nonexistent HOME="$T/nohome" "$IG" >/dev/null 2>&1; [ $? = 2 ] \
  && echo "ok policy lib missing fails closed for skill" || { echo "FAIL lib-missing closed"; fail=1; }
rec sonnet medium "Implement X" | SKILL_POLICY_LIB=/nonexistent HOME="$T/nohome" "$IG" >/dev/null 2>&1; [ $? = 0 ] \
  && echo "ok policy lib missing leaves ordinary spawn alone" || { echo "FAIL lib-missing ordinary"; fail=1; }
[ -x "$G" ] && echo "ok guard executable" || { echo "FAIL not executable"; fail=1; }
[ "$fail" = 0 ] && echo "PASS skill-agent-effort-guard" || { echo "FAILED skill-agent-effort-guard"; exit 1; }
