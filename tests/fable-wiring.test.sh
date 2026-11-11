#!/usr/bin/env bash
# A1169: the wiring, not wrapper flags. Runs the settings.json hook command with Agent payloads in both directions and greps skill/gate recipes.
# Hermetic: reads the repo tree ($H = repo root, whose .claude/ and .local/ mirror the installed layout), never the live home, so it passes on a fresh box.
# WM_LIVE_WIRING=1 adds the live-install parity check (installed launcher = repo copy) on the host that owns the install.
set -u
H="$(cd "$(dirname "$0")/.." && pwd)"; p=0; f=0; ck(){ if eval "$2"; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1"; fi; }
cmd=$(jq -r '.hooks.PreToolUse[]|select(.matcher=="Agent")|.hooks[]|.command|select(test("fable-native-agent-guard"))' "$H/.claude/settings.json" | head -1)
cmd="$H/.claude/hooks/$(basename "$cmd")"   # settings.json carries the installed absolute path; run the repo copy of the same hook
ck "settings.json wires the guard on Agent" '[ -x "$cmd" ]'
r(){ printf '{"tool_name":"Agent","tool_input":{"model":"%s","effort":"%s"}}' "$2" "${3-}" | FABLE_LAUNCH_ACCOUNT="$1" "$cmd"; }
ck "wired: jyen.pm parent + native sonnet denied" 'r jyen.pm sonnet | grep -q deny'
ck "wired: josephsyen parent + native fable denied" 'r josephsyen fable | grep -q deny'
ck "wired: jyen.pm parent + omitted model denied" 'r jyen.pm "" | grep -q deny'
ck "wired: jyen.pm parent + native fable high allowed" '[ -z "$(r jyen.pm fable high)" ]'
ck "wired: jyen.pm parent + native fable xhigh denied (reasoned exception, launcher only)" 'r jyen.pm fable xhigh | grep -q deny'
for s in 5whysandrhyme wwhtbt; do ck "$s SKILL.md names fable-launch" 'grep -q fable-launch.sh "$H/.claude/skills/'$s'/SKILL.md" && ! grep -q "run it as \`Agent(model=fable" "$H/.claude/skills/'$s'/SKILL.md"'; done
ck "spawn-gate recipe uses fable-launch, not Agent(model=fable" 'grep -q fable-launch.sh "$H/.claude/hooks/fable-skill-spawn-gate.sh" && ! grep -q "Agent(subagent_type=general-purpose, model=fable" "$H/.claude/hooks/fable-skill-spawn-gate.sh"'
ck "transition executor uses fable-launch, no raw claude with fable" 'grep -q fable-launch.sh "$H/.local/bin/ctl-fable-xhigh-transition.sh" && ! grep -qE "bin/claude\" .*claude-fable" "$H/.local/bin/ctl-fable-xhigh-transition.sh"'
[ "${WM_LIVE_WIRING:-0}" = 1 ] && ck "launcher installed = repo copy" 'cmp -s "$HOME/.local/bin/fable-launch.sh" "$H/.local/bin/fable-launch.sh"'
echo "pass=$p fail=$f"; [ $f = 0 ] && echo ALL PASS
