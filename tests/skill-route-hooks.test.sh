#!/usr/bin/env bash
# skill-route-hooks.test.sh: directly typed slash + Skill + native-agent surfaces of adaptive skill routing (ledger A1300).
# Fake hook inputs only; no provider call. Run alone: bash tests/skill-route-hooks.test.sh
set -u
R="$(cd "$(dirname "$0")/.." && pwd)"
PG="$R/.claude/hooks/skill-route-prompt-guard.sh"; SG="$R/.claude/hooks/fable-skill-spawn-gate.sh"
EG="$R/.claude/hooks/skill-agent-effort-guard.sh"; NG="$R/.claude/hooks/fable-native-agent-guard.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export SKILL_MARKER_DIR="$T/marks" FABLE_SKILLS_DIR="$T/skills" ANALYSIS_ROUTER_LOG="$T/r.jsonl"
unset SKILL_ROUTE_TASK_ID SKILL_ROUTE_SKILL FABLE_LAUNCH_ACCOUNT SKILL_ROUTE_POLICY
p=0; f=0; ck(){ if eval "$2"; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1"; fi; }
pg(){ jq -cn --arg p "$1" '{prompt:$p,session_id:"s1"}' | "$PG" 2>/dev/null; }
blocked(){ printf '%s' "$1" | jq -e '.decision=="block"' >/dev/null 2>&1; }
# --- directly typed slash expansion
for s in 5whysandrhyme wwhtbt; do
  o=$(pg "/$s five whys on the stall"); ck "typed /$s is blocked with the managed recipe" 'blocked "$o" && printf %s "$o" | grep -q -- "--route-request"'
done
o=$(pg "/plugin:wwhtbt plan"); ck "namespaced typed /x:wwhtbt blocked" 'blocked "$o"'
o=$(pg "  /wwhtbt"); ck "leading whitespace does not evade" 'blocked "$o"'
o=$(SKILL_ROUTE_TASK_ID=A1 SKILL_ROUTE_SKILL=wwhtbt pg "/wwhtbt plan X"); ck "managed worker for that skill may expand its own slash" '[ -z "$o" ]'
o=$(SKILL_ROUTE_TASK_ID=A1 SKILL_ROUTE_SKILL=wwhtbt pg "/5whysandrhyme x"); ck "managed worker for another skill is still blocked" 'blocked "$o"'
for s in write beauty improv nosuch; do o=$(pg "/$s something"); ck "typed /$s (ungoverned) untouched" '[ -z "$o" ]'; done
o=$(pg "do a five whys on this"); ck "plain analysis words pass (router only points)" '[ -z "$o" ]'
o=$(pg "please run /wwhtbt later"); ck "slash mid-sentence not expanded by harness -> passes" '[ -z "$o" ]'
N=$'\n'; o=$(pg "<system-reminder>${N}/wwhtbt${N}</system-reminder>${N}status"); ck "slash inside a harness block ignored" '[ -z "$o" ]'
o=$(pg '/wwhtbt $(touch '"$T"'/pwned) `touch '"$T"'/pwned2`'); ck "hostile args stay data" 'blocked "$o" && [ ! -e "$T/pwned" ] && [ ! -e "$T/pwned2" ]'
echo '{"prompt":' | "$PG" >/dev/null 2>&1; ck "malformed hook input fails open (declared residual)" '[ $? = 0 ]'
echo '{' >"$T/bad.json"
o=$(SKILL_ROUTE_POLICY="$T/bad.json" pg "/wwhtbt x"); ck "malformed policy: governed-name slash fails closed" 'blocked "$o"'
o=$(SKILL_ROUTE_POLICY="$T/bad.json" pg "/write x"); ck "malformed policy: unrelated slash still usable" '[ -z "$o" ]'
# --- Skill tool surface
sk(){ jq -cn --arg s "$1" '{tool_name:"Skill",tool_input:{skill:$s},tool_use_id:"tu1",session_id:"s1"}' | "$SG" >/dev/null 2>&1; echo $?; }
ck "Skill 5whysandrhyme inline denied" '[ "$(sk 5whysandrhyme)" = 2 ]'
ck "Skill wwhtbt inline denied" '[ "$(sk wwhtbt)" = 2 ]'
ck "Skill write untouched" '[ "$(sk write)" = 0 ]'
ck "Skill write unchanged (no SKILL.md here -> allowed)" '[ "$(sk write)" = 0 ]'
ck "Skill wwhtbt inside its managed worker allowed" '[ "$(SKILL_ROUTE_TASK_ID=A1 SKILL_ROUTE_SKILL=wwhtbt sk wwhtbt)" = 0 ]'
ck "Skill governed + malformed policy fails closed" '[ "$(SKILL_ROUTE_POLICY="$T/bad.json" sk wwhtbt)" = 2 ]'
ck "Skill non-governed + malformed policy still allowed" '[ "$(SKILL_ROUTE_POLICY="$T/bad.json" sk write)" = 0 ]'
# --- native Agent surface: baseline only, account safeguard intact
ag(){ jq -cn --arg m "$1" --arg e "$2" --arg p "$3" '{tool_name:"Agent",tool_input:({prompt:$p}+(if $m=="" then {} else {model:$m} end)+(if $e=="" then {} else {effort:$e} end))}'; }
W='Invoke the wwhtbt skill (Skill tool, skill: wwhtbt) on plan X.'; F='Invoke the 5whysandrhyme skill (Skill tool, skill: 5whysandrhyme) on the stall.'
ck "native sonnet/medium wwhtbt (baseline) passes effort guard" 'ag sonnet medium "$W" | "$EG" >/dev/null 2>&1'
ck "native wwhtbt sonnet/high denied" '! ag sonnet high "$W" | "$EG" >/dev/null 2>&1'
ck "native fable/max denied (no implicit Fable max)" '! ag fable max "$F" | "$EG" >/dev/null 2>&1'
ck "native codex/gpt model denied (no implicit fallback)" '! ag gpt-5-codex high "$F" | "$EG" >/dev/null 2>&1'
ck "unrelated native spawn untouched" 'ag sonnet medium "Implement the parser" | "$EG" >/dev/null 2>&1'
o=$(ag sonnet medium "$W" | FABLE_LAUNCH_ACCOUNT=jyen.pm "$NG"); ck "account safeguard: sonnet child under a jyen.pm Fable parent still denied" 'printf %s "$o" | grep -q deny'
o=$(ag sonnet medium "$W" | "$NG"); ck "account safeguard: sonnet child under josephsyen parent allowed" '[ -z "$o" ]'
o=$(ag fable high "$F" | "$NG"); ck "account safeguard: native Fable on josephsyen denied, names --route-request" 'printf %s "$o" | grep -q deny && printf %s "$o" | grep -q -- "--route-request"'
ck "effort guard fails closed without helpers (skill-shaped spawn only)" '! (mkdir -p "$T/iso/.claude/hooks"; cp "$EG" "$T/iso/.claude/hooks/"; ag sonnet medium "$W" | SKILL_ROUTE_LIB=/nonexistent HOME="$T/nohome" "$T/iso/.claude/hooks/skill-agent-effort-guard.sh" >/dev/null 2>&1)'
jq -e '[.hooks.UserPromptSubmit[]|.hooks[]|select(.command|endswith("skill-route-prompt-guard.sh"))]|length==1' "$R/.claude/settings.json" >/dev/null; ck "prompt guard wired in settings.json" '[ $? = 0 ]'
echo "pass=$p fail=$f"; [ $f = 0 ] && echo ALL PASS
