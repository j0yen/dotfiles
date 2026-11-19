#!/usr/bin/env bash
# analysis-route AC 7 (A1300 E13): the unchanged skill-agent-effort-guard.sh and model-effort-audit.sh over the policy under test. A native
# Agent spawn asking opus high or xhigh with a 5whysandrhyme or wwhtbt invoke or review prompt exits 2 as at f9066716 (its request names no
# route, so it never selects an alternate); fable high (5whysandrhyme) and sonnet medium (wwhtbt) still exit 0; the whole matrix equals the
# guard's answers over the vendored f9066716 resolver and policy; the audit's routing checks pass and its SKILL.md pin info line is quiet.
# From R (AR_ROOT): guard, audit, libs, resolver, policy, hooks and the tracked analysis SKILL.md files.
# Run alone: bash tests/analysis-route_ac07_guard_audit.test.sh
. "$(dirname "$0")/analysis-route_lib.sh"
G="$R/.claude/hooks/skill-agent-effort-guard.sh"
ck "vendored f9066716 resolver and policy present with their full sha256 digests (missing or changed = FAIL)" 'ar_fixtures_ok'
ck "skill-agent-effort-guard.sh and model-effort-audit.sh are f9066716's bytes (unchanged by this PRD)" 'ar_sha "$G" de1d2431139950f6a6235e8416bee3186dbfd24e4ef84a3e52e6f8f1bf47add6 && ar_sha "$R/.local/bin/model-effort-audit.sh" fd1de51f7b50782efe7428edc3dc0f90de2b2bd3d584f8995633b63f77b013e5'
# guard PROMPT MODEL EFFORT [base]: the guard's exit code, private HOME, the tree's libs; "base" swaps in the vendored f9066716 resolver+policy
guard(){ local pol="$R/.config/skill-routing/policy.json" res="$R/.local/lib/skill-route-resolve.py"; [ "${4:-}" = base ] && { pol="$BPOL"; res="$BRES"; }
  jq -cn --arg p "$1" --arg m "$2" --arg e "$3" '{tool_name:"Agent",tool_input:({prompt:$p,subagent_type:"general-purpose"} + (if $m=="" then {} else {model:$m} end) + (if $e=="" then {} else {effort:$e} end))}' \
  | env -i PATH="$PATH" HOME="$T/home" SKILL_POLICY_LIB="$R/.local/lib/skill-model-policy.sh" SKILL_ROUTE_LIB="$R/.local/lib/skill-route.sh" \
      SKILL_ROUTE_POLICY="$pol" SKILL_ROUTE_RESOLVER="$res" bash "$G" >/dev/null 2>"$T/g.err"; echo $?; }
P5I='Invoke the 5whysandrhyme skill (Skill tool, skill: 5whysandrhyme, args: stoppage). Return the page path.'
P5R='Independent review of the 5whysandrhyme page ~/Notes/wiki/answers/x.md: return verdict lines.'
PWI='Run the wwhtbt skill on plan X and file the page.'
PWR='Independent review of the wwhtbt page ~/Notes/wiki/decisions/x.md: return verdict lines.'
n=0; bad=0; : >"$T/m.head"; : >"$T/m.base"
for pr in "$P5I" "$P5R" "$PWI" "$PWR"; do for me in "opus high" "opus xhigh" "claude-opus-5-5 high" "claude-opus-5-5 xhigh"; do
  set -- $me; n=$((n+1)); h=$(guard "$pr" "$1" "$2"); b=$(guard "$pr" "$1" "$2" base); echo "$h $1 $2 $pr" >>"$T/m.head"; echo "$b $1 $2 $pr" >>"$T/m.base"
  [ "$h" = 2 ] && [ "$b" = 2 ] || { bad=$((bad+1)); echo "  opus spawn $1/$2 rc head=$h base=$b: $pr"; }
done; done
ck "native Agent spawns on opus high/xhigh (alias or full id) with a 5whysandrhyme or wwhtbt invoke or review prompt exit 2, as at f9066716 ($n cases)" '[ "$n" = 16 ] && [ "$bad" = 0 ]'
ck "5whysandrhyme invoke and review on fable high still exit 0" '[ "$(guard "$P5I" fable high)" = 0 ] && [ "$(guard "$P5R" fable high)" = 0 ] && [ "$(guard "$P5I" claude-fable-5-1 high)" = 0 ]'
ck "wwhtbt invoke on sonnet medium still exits 0" '[ "$(guard "$PWI" sonnet medium)" = 0 ] && [ "$(guard "$PWI" claude-sonnet-5-5 medium)" = 0 ]'
for pr in "$P5I" "$P5R" "$PWI" "$PWR"; do for me in "fable high" "fable xhigh" "sonnet medium" "fable max" "haiku default" ". ."; do
  set -- $me; m=$1; e=$2; [ "$m" = . ] && m="" && e=""; echo "$(guard "$pr" "$m" "$e") $m $e $pr" >>"$T/m.head"; echo "$(guard "$pr" "$m" "$e" base) $m $e $pr" >>"$T/m.base"
done; done
ck "the guard's whole matrix (4 prompts x 10 model/effort pairs) is identical over the head and the f9066716 resolver and policy" '[ "$(wc -l <"$T/m.head")" = 40 ] && cmp -s "$T/m.head" "$T/m.base"' || diff "$T/m.base" "$T/m.head" | head -6

# the audit over a fake HOME built from the tree under test (tests/model-effort-audit.test.sh's build), with the tracked analysis SKILL.md files
H="$T/ah"; mkdir -p "$H/.local/lib" "$H/.local/bin" "$H/.claude/hooks" "$H/.claude/skills" "$H/.config/wm-decide" "$H/.config/aide" "$H/.cache" "$H/.config/skill-routing" "$H/.local/state/skill-routing" "$H/.claude/projects/p"
cp "$R/.local/lib/ctl-model-policy.sh" "$R/.local/lib/skill-model-policy.sh" "$R/.local/lib/skill-route.sh" "$R/.local/lib/skill-route-resolve.py" "$H/.local/lib/"
cp "$R/.config/skill-routing/policy.json" "$H/.config/skill-routing/"
cp "$R/.local/bin/ctl-launch.sh" "$R/.local/bin/ctl-relaunch.sh" "$R/.local/bin/aide-launch.sh" "$R/.local/bin/aide-relaunch.sh" "$H/.local/bin/"
cp "$R/.claude/hooks/fable-skill-spawn-gate.sh" "$R/.claude/hooks/skill-agent-effort-guard.sh" "$R/.claude/hooks/skill-route-prompt-guard.sh" "$H/.claude/hooks/"
for s in 5whysandrhyme wwhtbt; do mkdir -p "$H/.claude/skills/$s"; cp "$R/.claude/skills/$s/SKILL.md" "$H/.claude/skills/$s/SKILL.md"; done
mkdir -p "$H/.claude/skills/maxspeed"; printf -- '---\nname: maxspeed\nfable-spawn: true\n---\nbody\n' >"$H/.claude/skills/maxspeed/SKILL.md"
mkdir -p "$H/.claude/skills/dream"; printf -- '---\nname: dream\nmodel: fable\neffort: max\nfable-spawn: true\n---\n' >"$H/.claude/skills/dream/SKILL.md"
jq -n '{ctl:{model:"claude-sonnet-5-5",effort:"medium"},aide:{model:"claude-sonnet-5-5",effort:"medium"},rb:{model:"claude-opus-5-5"}}' >"$H/.config/wm-decide/seat-model-hold.json"
jq -n --arg g "$H/.claude/hooks/skill-agent-effort-guard.sh" '{model:"claude-sonnet-5-5",modelSettings:{"claude-sonnet-5-5":{effortLevel:"medium"},"claude-fable-5-1":{effortLevel:"high"}},env:{CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:"50"},hooks:{PreToolUse:[{matcher:"Agent",hooks:[{type:"command",command:$g}]}],UserPromptSubmit:[{hooks:[{type:"command",command:"/x/skill-route-prompt-guard.sh"}]}]}}' >"$H/.claude/settings.json"
printf '{"model":"claude-sonnet-5-5","effortLevel":"high"}\n' >"$H/.claude/settings.local.json"
printf '#!/bin/sh\ncase "$*" in *is-active*) echo inactive;; esac\n' >"$T/systemctl"; chmod +x "$T/systemctl"
printf '#!/bin/sh\nexit 0\n' >"$T/notify"; chmod +x "$T/notify"; : >"$T/procs"
out=$(env -u SKILL_ROUTE_POLICY HOME="$H" XDG_CONFIG_HOME="$H/.config" MEA_SYSTEMCTL="$T/systemctl" MEA_PROCS="$T/procs" MEA_NOTIFY="$T/notify" MEA_STATE="$T/mea-state" \
  MEA_PROJECTS="$H/.claude/projects" MEA_DECISIONS="$H/.local/state/skill-routing/decisions.jsonl" "$R/.local/bin/model-effort-audit.sh" 2>/dev/null); arc=$?
ck "audit over the policy under test: exit 0, no findings (routing baselines, max denied, free-text escalation denied, gates, guard)" '[ "$arc" = 0 ] && jq -e ".ok and (.findings|length)==0" <<<"$out" >/dev/null 2>&1' || jq -c .findings <<<"$out" 2>/dev/null | head -c 600
ck "audit: no routing-, gate-, guard- or skill- finding id" '! jq -e "[.findings[].id|select(test(\"^(routing|gate|guard|slash|skill)-\"))]|length>0" <<<"$out" >/dev/null 2>&1 && jq -e ".findings" <<<"$out" >/dev/null 2>&1'
ck "audit: the SKILL.md pin info line is quiet for both analysis skills (R5; success metric)" 'jq -e ".info" <<<"$out" >/dev/null 2>&1 && ! jq -e "[.info[]|select(test(\"(5whysandrhyme|wwhtbt) SKILL.md still pins\"))]|length>0" <<<"$out" >/dev/null 2>&1'
ar_end
