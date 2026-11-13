#!/usr/bin/env bash
# skill-maxspeed-policy.test.sh: A1300 AC5/AC5b-e/AC6 — maxspeed governed by the routing policy with require_permission_mode.
# Harmless fakes only: temp HOME, repo hook/lib/resolver symlinked in, no real claude, no network, no live policy read.
# Run alone: bash tests/skill-maxspeed-policy.test.sh   (BASE_TREE=<clone> adds the AC5e other-skills diff against that tree)
set -u
R="$(cd "$(dirname "$0")/.." && pwd)"
SLICE="${MS_SLICE:-/home/jsy/.cache/rb-seat/coders/ms-slice/maxspeed-policy-slice.json}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
p=0; f=0
ck(){ if eval "$2"; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1"; fi; }
POL="$R/.config/skill-routing/policy.json"
. "$R/.local/lib/skill-model-policy.sh"

# AC5 set equality + provenance
ck "AC5 policy keys == SKILL_POLICY_SKILLS" '[ "$(jq -r ".skills|keys[]" "$POL" | sort)" = "$(tr " " "\n" <<<"$SKILL_POLICY_SKILLS" | sort)" ]'
ck "AC5 maxspeed listed once" '[ "$(tr " " "\n" <<<"$SKILL_POLICY_SKILLS" | grep -cx maxspeed)" = 1 ]'
if [ -r "$SLICE" ]; then
  ck "AC5 slice raw sha a7e223b5" '[ "$(sha256sum <"$SLICE" | cut -d" " -f1)" = a7e223b526bf744526f34e4f1da478d6ec361d3e342ea76bd7176944e6b40b0d ]'
  ck "AC5 .skills.maxspeed == slice (jq -S -c sha)" '[ "$(jq -S -c .skills.maxspeed "$POL" | sha256sum)" = "$(jq -S -c .maxspeed "$SLICE" | sha256sum)" ]'
  ck "AC5 .skills.maxspeed == slice (jq -c unsorted)" '[ "$(jq -c .skills.maxspeed "$POL")" = "$(jq -c .maxspeed "$SLICE")" ]'
else echo "SKIP slice provenance (no $SLICE)"; fi

# harness: temp HOME, repo files symlinked, policy via $HOME path
mkhome(){ # dir tree
  local h="$1" t="$2"; mkdir -p "$h/.config/skill-routing" "$h/.local/lib" "$h/.claude/hooks"
  ln -sf "$t/.config/skill-routing/policy.json" "$h/.config/skill-routing/policy.json"
  for l in skill-model-policy.sh skill-route.sh skill-route-resolve.py; do ln -sf "$t/.local/lib/$l" "$h/.local/lib/$l"; done
  ln -sf "$t/.claude/hooks/skill-agent-effort-guard.sh" "$h/.claude/hooks/skill-agent-effort-guard.sh"; }
H="$T/home"; mkhome "$H" "$R"
for l in .local/lib/skill-route-resolve.py .local/lib/skill-model-policy.sh .claude/hooks/skill-agent-effort-guard.sh; do
  ck "harness realpath $l is the repo file" '[ "$(realpath "$H/$l")" = "$(realpath "$R/$l")" ]'; done
: >"$T/ev"
# payload shape derived from the PreToolUse hook input (common fields + tool_input); only model/effort/permission_mode/prompt vary
payload(){ # model effort mode prompt
  jq -cn --arg m "$1" --arg e "$2" --arg pm "$3" --arg p "$4" '{session_id:"sid-1",transcript_path:"/tmp/x.jsonl",cwd:"/tmp",hook_event_name:"PreToolUse",tool_name:"Agent",tool_use_id:"tu-1",tool_input:({prompt:$p,subagent_type:"general-purpose"}+(if $m=="" then {} else {model:$m} end)+(if $e=="" then {} else {effort:$e} end))}
    + (if $pm=="" then {} else {permission_mode:$pm} end)'; }
g(){ # home model effort mode prompt -> rc, stdout/stderr in $T/o $T/e
  payload "$2" "$3" "$4" "$5" | env -i PATH="$PATH" HOME="$1" SKILL_ROUTE_POLICY="$1/.config/skill-routing/policy.json" "$1/.claude/hooks/skill-agent-effort-guard.sh" >"$T/o" 2>"$T/e"; }
MS='Invoke the maxspeed skill (Skill tool, skill: maxspeed, args: plan). Return the page.'
g "$H" fable high plan "$MS"; rc=$?; ck "AC5b maxspeed fable/high + plan -> allow" '[ $rc = 0 ]'
g "$H" sonnet medium plan "$MS"; rc=$?; ck "AC5c maxspeed sonnet/medium -> deny citing policy route" '[ $rc = 2 ] && grep -q "fable-high" "$T/e"'
g "$H" fable high default "$MS"; rc=$?; ck "AC5c maxspeed without plan mode -> deny naming require_permission_mode" '[ $rc = 2 ] && grep -q require_permission_mode "$T/e"'
g "$H" fable high "" "$MS"; rc=$?; ck "AC5c maxspeed with permission_mode absent -> deny" '[ $rc = 2 ] && grep -q require_permission_mode "$T/e"'
g "$H" fable xhigh plan "$MS"; rc=$?; ck "AC5c maxspeed xhigh without evidence -> deny" '[ $rc = 2 ]'
# class + evidence through the resolver in the same harness (the native guard carries baseline only by design)
rr(){ jq -cn --arg pm "$1" --arg ev "file:$T/ev" --argjson cls "$2" '{task_id:"t-1",skill:"maxspeed",requested:{model:"claude-fable-5-1",effort:"xhigh"}}+(if $cls then {decision_class:"unresolved_reasoning_gap",evidence_refs:[$ev]} else {} end)+(if $pm=="" then {} else {permission_mode:$pm} end)' \
  | HOME="$H" SKILL_ROUTE_POLICY="$H/.config/skill-routing/policy.json" python3 -I "$H/.local/lib/skill-route-resolve.py" >"$T/ro" 2>&1; }
rr plan true; rc=$?; ck "AC5b class unresolved_reasoning_gap + evidence -> fable-xhigh allowed" '[ $rc = 0 ] && jq -e ".route==\"fable-xhigh\"" "$T/ro" >/dev/null'
rr plan false; rc=$?; ck "AC5c xhigh requested at baseline -> deny" '[ $rc = 2 ]'
# AC5d fallback
ck "AC5d maxspeed appears in the guard only in comments" '! grep -v "^[[:space:]]*#" "$R/.claude/hooks/skill-agent-effort-guard.sh" | grep -q maxspeed'
for s in maxspeed 5whysandrhyme dream wwhtbt; do
  H2="$T/h-$s"; mkhome "$H2" "$R"; rm "$H2/.config/skill-routing/policy.json"
  g "$H2" fable high plan "Invoke the $s skill (Skill tool, skill: $s, args: x)."; rc=$?
  ck "AC5d-neg $s: policy deleted -> exit 2 policy-missing" '[ $rc = 2 ] && grep -q policy-missing "$T/e"'
done
# policy present but skill entry absent -> policy-missing
jq 'del(.skills.maxspeed)' "$POL" >"$T/nopol.json"; H3="$T/h3"; mkhome "$H3" "$R"; rm "$H3/.config/skill-routing/policy.json"; cp "$T/nopol.json" "$H3/.config/skill-routing/policy.json"
g "$H3" fable high plan "$MS"; rc=$?; ck "AC5d governed skill with no policy entry -> exit 2 policy-missing" '[ $rc = 2 ] && grep -q policy-missing "$T/e"'

# AC6 resolver unit
pe(){ # policyfile request
  python3 -I "$R/.local/lib/skill-route-resolve.py" --policy "$1" <<<"$2" >"$T/ro" 2>&1; }
RQ='{"task_id":"t-1","skill":"maxspeed","requested":{"model":"claude-fable-5-1","effort":"high"}'
pe "$POL" "$RQ"',"permission_mode":"plan"}'; rc=$?; ck "AC6 matching mode allows" '[ $rc = 0 ]'
pe "$POL" "$RQ"',"permission_mode":"default"}'; rc=$?; ck "AC6 different mode denies naming field" '[ $rc = 2 ] && grep -q require_permission_mode "$T/ro"'
pe "$POL" "$RQ"'}'; rc=$?; ck "AC6 absent mode denies" '[ $rc = 2 ] && grep -q require_permission_mode "$T/ro"'
pe "$POL" "$RQ"',"permission_mode":null}'; rc=$?; ck "AC6 null mode denies" '[ $rc = 2 ]'
pe "$POL" "$RQ"',"permission_mode":""}'; rc=$?; ck "AC6 empty mode denies" '[ $rc = 2 ]'
for v in '""' null 3 true '["plan"]' '{"a":1}'; do
  jq --argjson v "$v" '.skills.maxspeed.require_permission_mode=$v' "$POL" >"$T/bad.json"
  pe "$T/bad.json" "$RQ"',"permission_mode":"plan"}'; rc=$?; ck "AC6 policy value $v fails closed" '[ $rc = 2 ]'
done
pe "$POL" '{"task_id":"t-1","skill":"wwhtbt","requested":{"model":"claude-sonnet-5-5","effort":"medium"}}'; rc=$?; ck "AC6 skill without the field unaffected" '[ $rc = 0 ]'
# guard stdin
for in in '' '{"tool_name":"Agent"'; do
  printf '%s' "$in" | env -i PATH="$PATH" HOME="$H" "$H/.claude/hooks/skill-agent-effort-guard.sh" >/dev/null 2>&1; rc=$?
  ck "guard malformed/empty stdin exit 2 ($(printf '%s' "$in" | wc -c) bytes)" '[ $rc = 2 ]'; done

# AC5e other skills unchanged vs a base tree (BASE_TREE)
if [ -n "${BASE_TREE:-}" ]; then
  HB="$T/hb"; mkhome "$HB" "$BASE_TREE"
  S5='Invoke the 5whysandrhyme skill (Skill tool, skill: 5whysandrhyme, args: x).'; SW='Run the wwhtbt skill on plan X.'; SD='Invoke the dream skill (Skill tool, skill: dream, args: x).'
  matrix(){ # home -> stable transcript
    local hh="$1" n=0; for c in "fable high|$S5" "fable xhigh|$S5" "fable medium|$S5" "sonnet medium|$SW" "fable xhigh|$SW" "fable high|$SW" "sonnet medium|$SD" "fable high|$SD" "|$S5"; do
      m="${c%% *}"; rest="${c#* }"; e="${rest%%|*}"; pr="${rest#*|}"; [ "${c%%|*}" = "" ] && { m=""; e=""; pr="$S5"; }
      g "$hh" "$m" "$e" plan "$pr"; echo "case$n rc=$? out=$(cat "$T/o") err=$(cat "$T/e")"; n=$((n+1)); done; }
  matrix "$H" >"$T/mh.txt"; matrix "$HB" >"$T/mb.txt"
  ck "AC5e 5whysandrhyme/dream/wwhtbt matrix identical base vs head" 'diff -u "$T/mb.txt" "$T/mh.txt" >"$T/mdiff"; [ ! -s "$T/mdiff" ] || { cat "$T/mdiff"; false; }'
fi
echo "pass=$p fail=$f"; [ $f = 0 ] && echo ALL PASS
[ $f = 0 ]
