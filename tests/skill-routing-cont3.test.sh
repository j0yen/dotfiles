#!/usr/bin/env bash
# skill-routing-cont3.test.sh: A1300 continuation 3 (Fable exact-head review edits 3,4,7,8,9; edit 2 in skill-route-permission-source.test.sh).
# Harmless fakes only: temp HOME, fake claude spy, repo files; no real claude, no credential, no network.
# Run alone: bash tests/skill-routing-cont3.test.sh   (edit 6 audit cases live in tests/model-effort-audit.test.sh)
set -u
R="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
p=0; f=0
ck(){ if eval "$2"; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1"; fi; }
POL="$R/.config/skill-routing/policy.json"
MS='Invoke the maxspeed skill (Skill tool, skill: maxspeed, args: plan). Return the page.'
pay(){ jq -cn --arg m "$1" --arg e "$2" --arg pm "$3" --arg p "$4" '{hook_event_name:"PreToolUse",tool_name:"Agent",tool_input:{prompt:$p,subagent_type:"general-purpose",model:$m,effort:$e}}+(if $pm=="" then {} else {permission_mode:$pm} end)'; }

# edit 3: guard sourcing a lib without sr_governed -> its own message, not policy-missing
printf 'sr_resolve(){ echo "{}"; return 0; }\nsr_alias_model(){ printf "%%s" "$1"; }\nsr_recipe(){ :; }\n' >"$T/oldlib.sh"
pay fable high plan "$MS" | env -i PATH="$PATH" HOME="$T" SKILL_ROUTE_LIB="$T/oldlib.sh" SKILL_ROUTE_POLICY="$POL" "$R/.claude/hooks/skill-agent-effort-guard.sh" >"$T/o" 2>"$T/e"; rc=$?
ck "edit3 lib without sr_governed -> exit 2" '[ $rc = 2 ]'
ck "edit3 message names sr_governed (install skew)" 'grep -q "sr_governed" "$T/e"'
ck "edit3 message is not policy-missing" '! grep -q "policy-missing" "$T/e"'

# edit 4: explicit --policy file that does not exist is denied, no fall-through to repo/home policy
mkdir -p "$T/h/.config/skill-routing"; cp "$POL" "$T/h/.config/skill-routing/policy.json"
printf '{"task_id":"t-1","skill":"wwhtbt"}' | env -i PATH="$PATH" HOME="$T/h" python3 -I "$R/.local/lib/skill-route-resolve.py" --policy "$T/nope.json" >"$T/ro" 2>&1; rc=$?
ck "edit4 missing --policy file -> exit 2 policy-missing (repo + home policy present)" '[ $rc = 2 ] && grep -q "policy-missing" "$T/ro"'
printf '{"task_id":"t-1","skill":"wwhtbt"}' | env -i PATH="$PATH" HOME="$T/h" python3 -I "$R/.local/lib/skill-route-resolve.py" --policy "$POL" >"$T/ro" 2>&1; rc=$?
ck "edit4 existing --policy file still resolves" '[ $rc = 0 ]'
printf '{"task_id":"t-1","skill":"wwhtbt"}' | env -i PATH="$PATH" HOME="$T/h" python3 -I "$R/.local/lib/skill-route-resolve.py" >"$T/ro" 2>&1; rc=$?
ck "edit4 no --policy, no env: repo policy still found" '[ $rc = 0 ]'

# cont4 item 8: --policy wins over SKILL_ROUTE_POLICY (docstring order), no fall-through either way
printf '{"task_id":"t-1","skill":"wwhtbt"}' | env -i PATH="$PATH" HOME="$T/h" SKILL_ROUTE_POLICY="$T/nope.json" python3 -I "$R/.local/lib/skill-route-resolve.py" --policy "$POL" >"$T/ro" 2>&1; rc=$?
ck "cont4 --policy valid beats SKILL_ROUTE_POLICY missing" '[ $rc = 0 ]'
printf '{"task_id":"t-1","skill":"wwhtbt"}' | env -i PATH="$PATH" HOME="$T/h" SKILL_ROUTE_POLICY="$POL" python3 -I "$R/.local/lib/skill-route-resolve.py" --policy "$T/nope.json" >"$T/ro" 2>&1; rc=$?
ck "cont4 --policy missing beats SKILL_ROUTE_POLICY valid -> policy-missing" '[ $rc = 2 ] && grep -q "policy-missing" "$T/ro"'

# edit 7: native xhigh deny text names the launcher route-request path
pay fable xhigh plan "$MS" | env -i PATH="$PATH" HOME="$T/h" SKILL_ROUTE_POLICY="$POL" "$R/.claude/hooks/skill-agent-effort-guard.sh" >"$T/o" 2>"$T/e"; rc=$?
ck "edit7 maxspeed xhigh native -> deny" '[ $rc = 2 ]'
ck "edit7 deny text: only justified path = launcher route-request" 'grep -q "only justified path" "$T/e" && grep -q -- "--route-request" "$T/e" && grep -q decision_class "$T/e" && grep -q evidence_refs "$T/e"'

# edit 8: stale comment
ck "edit8 skill-model-policy.sh no longer says dream is absent" '! grep -qi "dream is deliberately absent" "$R/.local/lib/skill-model-policy.sh"'
# edit 9: no hard-coded home path, no unsorted jq -c equality in the maxspeed policy test
ck "edit9 maxspeed policy test has no /home/jsy path" '! grep -q "/home/jsy" "$R/tests/skill-maxspeed-policy.test.sh"'
ck "edit9 maxspeed policy test has no unsorted jq -c equality" '! grep -q "jq -c .skills.maxspeed" "$R/tests/skill-maxspeed-policy.test.sh"'

echo "p=$p f=$f"; [ "$f" = 0 ] && echo "ALL PASS" || exit 1
