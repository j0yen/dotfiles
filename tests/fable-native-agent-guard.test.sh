#!/usr/bin/env bash
# A1169: guard behavior before any native Agent call. One file, run as one command.
# A1300 FFDR R5: the guard takes the parent's lane from the model it was launched on, so every parent here pins FABLE_LAUNCH_MODEL beside
# FABLE_LAUNCH_ACCOUNT (as fable-launch.sh exports them); no live policy is read (hermetic). The deny texts name no account.
set -u
unset SKILL_ROUTE_ROLE SKILL_ROUTE_SESSION SKILL_ROUTE_SCOPE_ID SKILL_ROUTE_TASK_ID SKILL_ROUTE_SKILL SKILL_ROUTE_ROUTE SKILL_ROUTE_EFFORT FABLE_LAUNCH_ACCOUNT FABLE_LAUNCH_MODEL
G="$(cd "$(dirname "$0")/.." && pwd)/.claude/hooks/fable-native-agent-guard.sh"
p=0; f=0; ck(){ if eval "$2"; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1"; fi; }
# call ACCOUNT LAUNCH_MODEL CHILD_MODEL [EFFORT]: one Agent call under a parent launched on LAUNCH_MODEL (both empty = a plain session)
call(){ printf '{"tool_name":"Agent","tool_input":{"model":"%s","effort":"%s","subagent_type":"coder","prompt":"x"}}' "$3" "${4-high}" | FABLE_LAUNCH_ACCOUNT="$1" FABLE_LAUNCH_MODEL="$2" "$G"; }
denied(){ grep -q '"permissionDecision":"deny"' <<<"$1"; }
FP="jyen.pm claude-fable-5-1"   # a Fable parent (launched on claude-fable-5-1)
for m in sonnet haiku opus claude-sonnet-5-5 claude-haiku-5-5; do o=$(call $FP $m); ck "Fable parent (jyen.pm, claude-fable-5-1): native $m denied" 'denied "$o"'; done
o=$(call $FP fable); ck "Fable parent: native fable allowed" '[ -z "$o" ]'
o=$(call $FP claude-fable-5-1); ck "Fable parent: claude-fable-5-1 allowed" '[ -z "$o" ]'
o=$(call $FP ""); ck "Fable parent: omitted model (named coder) denied" 'denied "$o"'
o=$(printf '{"tool_name":"Agent","tool_input":{"subagent_type":"triage","prompt":"x"}}' | FABLE_LAUNCH_ACCOUNT=jyen.pm FABLE_LAUNCH_MODEL=claude-fable-5-1 "$G"); ck "Fable parent: model key absent (triage) denied" 'denied "$o"'
o=$(call $FP fable ""); ck "Fable parent: fable without effort denied" 'denied "$o"'
o=$(call $FP fable low); ck "Fable parent: fable low effort denied" 'denied "$o"'
o=$(call $FP fable max); ck "Fable parent: fable max denied (reasoned exceptions go through the launcher)" 'denied "$o"'
o=$(call $FP fable xhigh); ck "Fable parent: native fable xhigh denied (needs launcher + reason)" 'denied "$o" && grep -q FABLE_LAUNCH_EFFORT_REASON <<<"$o"'
o=$(printf 'not json' | FABLE_LAUNCH_ACCOUNT=jyen.pm FABLE_LAUNCH_MODEL=claude-fable-5-1 "$G"); ck "Fable parent: malformed input fails closed" 'denied "$o"'
o=$(printf 'not json' | FABLE_LAUNCH_ACCOUNT=josephsyen FABLE_LAUNCH_MODEL=claude-opus-5-5 "$G"); ck "non-Fable parent (josephsyen, claude-opus-5-5): malformed input fails open (declared residual)" '[ -z "$o" ]'
o=$(call josephsyen claude-opus-5-5 sonnet); ck "non-Fable parent: native sonnet allowed" '[ -z "$o" ]'
o=$(call "" "" haiku); ck "plain parent: native haiku allowed" '[ -z "$o" ]'
o=$(call "" "" fable); ck "plain parent: native fable denied -> launcher" 'denied "$o" && grep -q fable-launch.sh <<<"$o"'
o=$(call josephsyen claude-opus-5-5 claude-fable-5-1); ck "non-Fable parent: native fable denied" 'denied "$o"'
o=$(printf '{"tool_name":"Bash","tool_input":{"command":"x"}}' | FABLE_LAUNCH_ACCOUNT=jyen.pm FABLE_LAUNCH_MODEL=claude-fable-5-1 "$G"); ck "non-Agent tool ignored" '[ -z "$o" ]'
echo "pass=$p fail=$f"; [ $f = 0 ] && echo ALL PASS
