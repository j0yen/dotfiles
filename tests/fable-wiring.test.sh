#!/usr/bin/env bash
# A1169: the live wiring, not wrapper flags. Runs the settings.json hook command with Agent payloads in both directions and greps skill/gate recipes.
set -u
H="$HOME"; p=0; f=0; ck(){ if eval "$2"; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1"; fi; }
cmd=$(jq -r '.hooks.PreToolUse[]|select(.matcher=="Agent")|.hooks[]|.command|select(test("fable-native-agent-guard"))' "$H/.claude/settings.json" | head -1)
ck "settings.json wires the guard on Agent" '[ -x "$cmd" ]'
r(){ printf '{"tool_name":"Agent","tool_input":{"model":"%s"}}' "$2" | FABLE_LAUNCH_ACCOUNT="$1" "$cmd"; }
ck "wired: jyen.pm parent + native sonnet denied" 'r jyen.pm sonnet | grep -q deny'
ck "wired: josephsyen parent + native fable denied" 'r josephsyen fable | grep -q deny'
ck "wired: jyen.pm parent + native fable allowed" '[ -z "$(r jyen.pm fable)" ]'
for s in 5whysandrhyme wwhtbt; do ck "$s SKILL.md names fable-launch" 'grep -q fable-launch.sh "$H/.claude/skills/'$s'/SKILL.md" && ! grep -q "run it as \`Agent(model=fable" "$H/.claude/skills/'$s'/SKILL.md"'; done
ck "spawn-gate recipe uses fable-launch, not Agent(model=fable" 'grep -q fable-launch.sh "$H/.claude/hooks/fable-skill-spawn-gate.sh" && ! grep -q "Agent(subagent_type=general-purpose, model=fable" "$H/.claude/hooks/fable-skill-spawn-gate.sh"'
ck "transition executor uses fable-launch, no raw claude with fable" 'grep -q fable-launch.sh "$H/.local/bin/ctl-fable-xhigh-transition.sh" && ! grep -qE "bin/claude\" .*claude-fable" "$H/.local/bin/ctl-fable-xhigh-transition.sh"'
ck "launcher installed = repo copy" 'cmp -s "$H/.local/bin/fable-launch.sh" "$(dirname "$0")/../.local/bin/fable-launch.sh"'
echo "pass=$p fail=$f"; [ $f = 0 ] && echo ALL PASS
