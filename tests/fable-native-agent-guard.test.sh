#!/usr/bin/env bash
# A1169: guard behavior before any native Agent call. One file, run as one command.
set -u
G="$(cd "$(dirname "$0")/.." && pwd)/.claude/hooks/fable-native-agent-guard.sh"
p=0; f=0; ck(){ if eval "$2"; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1"; fi; }
call(){ printf '{"tool_name":"Agent","tool_input":{"model":"%s","effort":"%s","subagent_type":"coder","prompt":"x"}}' "$2" "${3-high}" | FABLE_LAUNCH_ACCOUNT="$1" "$G"; }
denied(){ grep -q '"permissionDecision":"deny"' <<<"$1"; }
for m in sonnet haiku opus claude-sonnet-5-5 claude-haiku-5-5; do o=$(call jyen.pm $m); ck "jyen.pm parent: native $m denied" 'denied "$o"'; done
o=$(call jyen.pm fable); ck "jyen.pm parent: native fable allowed" '[ -z "$o" ]'
o=$(call jyen.pm claude-fable-5-1); ck "jyen.pm parent: claude-fable-5-1 allowed" '[ -z "$o" ]'
o=$(call jyen.pm ""); ck "jyen.pm parent: omitted model (named coder) denied" 'denied "$o"'
o=$(printf '{"tool_name":"Agent","tool_input":{"subagent_type":"triage","prompt":"x"}}' | FABLE_LAUNCH_ACCOUNT=jyen.pm "$G"); ck "jyen.pm parent: model key absent (triage) denied" 'denied "$o"'
o=$(call jyen.pm fable ""); ck "jyen.pm parent: fable without effort denied" 'denied "$o"'
o=$(call jyen.pm fable low); ck "jyen.pm parent: fable low effort denied" 'denied "$o"'
o=$(call jyen.pm fable max); ck "jyen.pm parent: fable max denied (reasoned exceptions go through the launcher)" 'denied "$o"'
o=$(call jyen.pm fable xhigh); ck "jyen.pm parent: native fable xhigh denied (needs launcher + reason)" 'denied "$o" && grep -q FABLE_LAUNCH_EFFORT_REASON <<<"$o"'
o=$(printf 'not json' | FABLE_LAUNCH_ACCOUNT=jyen.pm "$G"); ck "jyen.pm parent: malformed input fails closed" 'denied "$o"'
o=$(printf 'not json' | FABLE_LAUNCH_ACCOUNT=josephsyen "$G"); ck "josephsyen parent: malformed input fails open (declared residual)" '[ -z "$o" ]'
o=$(call josephsyen sonnet); ck "josephsyen parent: native sonnet allowed" '[ -z "$o" ]'
o=$(call "" haiku); ck "plain parent: native haiku allowed" '[ -z "$o" ]'
o=$(call "" fable); ck "plain parent: native fable denied -> launcher" 'denied "$o" && grep -q fable-launch.sh <<<"$o"'
o=$(call josephsyen claude-fable-5-1); ck "josephsyen parent: native fable denied" 'denied "$o"'
o=$(printf '{"tool_name":"Bash","tool_input":{"command":"x"}}' | FABLE_LAUNCH_ACCOUNT=jyen.pm "$G"); ck "non-Agent tool ignored" '[ -z "$o" ]'
echo "pass=$p fail=$f"; [ $f = 0 ] && echo ALL PASS
