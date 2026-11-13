#!/usr/bin/env bash
# pretooluse-agent-real-payload.test.sh: A1300 cont4 AC1/AC2 — the committed guard run on REAL client PreToolUse Agent payloads
# (captured by Claude Code 2.1.293, see tests/fixtures/pretooluse-agent.PROVENANCE.md). Variants are jq edits of the captured
# tool_input.subagent_type/model/prompt and the VALUE of top-level effort.level; every variant with a changed effort.level is derived-*
# (DERIVED, not client-captured high provenance). Harmless fakes only: temp HOME with the repo policy, no real claude, no network.
# Run alone: bash tests/pretooluse-agent-real-payload.test.sh
set -u
R="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
p=0; f=0
ck(){ if eval "$2"; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1"; fi; }
FX="$R/tests/fixtures"; PLAN="$FX/pretooluse-agent-plan.json"; DEF="$FX/pretooluse-agent-default.json"

# AC1 fixtures byte-equal to the recorded sha256 (full 64-hex from PROVENANCE.md)
ck "AC1 plan fixture sha256" '[ "$(sha256sum <"$PLAN" | cut -d" " -f1)" = 86012436ca00dd1e3c03d225377f88e061fc72fb38defa6835dffc2f96e32851 ]'
ck "AC1 default fixture sha256" '[ "$(sha256sum <"$DEF" | cut -d" " -f1)" = 1abc0d29b14da9c6d89d6a6cabe9fa0ea66ccaab17593a9f5695734ac5f31f85 ]'
ck "AC1 PROVENANCE records both full shas" 'grep -q 86012436ca00dd1e3c03d225377f88e061fc72fb38defa6835dffc2f96e32851 "$FX/pretooluse-agent.PROVENANCE.md" && grep -q 1abc0d29b14da9c6d89d6a6cabe9fa0ea66ccaab17593a9f5695734ac5f31f85 "$FX/pretooluse-agent.PROVENANCE.md"'
ck "AC1 real shape: no tool_input.effort, top-level effort.level=low" '! jq -e ".tool_input|has(\"effort\")" "$PLAN" >/dev/null && [ "$(jq -r .effort.level "$PLAN")" = low ]'

# harness: temp HOME carrying only the repo policy; guard/lib are the committed repo files
H="$T/home"; mkdir -p "$H/.config/skill-routing"; cp "$R/.config/skill-routing/policy.json" "$H/.config/skill-routing/policy.json"
MS='Invoke the maxspeed skill (Skill tool, skill: maxspeed, args: plan). Return the page.'
g(){ # json -> rc, stdout/stderr in $T/o $T/e
  printf '%s' "$1" | env -i PATH="$PATH" HOME="$H" "$R/.claude/hooks/skill-agent-effort-guard.sh" >"$T/o" 2>"$T/e"; }
# a spawn that names a model must name tool_input.effort too (cont6): v copies the captured top-level level into tool_input.effort;
# vn is the real client shape (no tool_input.effort)
v(){ jq -c --arg m "$2" --arg p "$MS" '.tool_input.model=$m|.tool_input.prompt=$p|.tool_input.subagent_type="general-purpose"|.tool_input.effort=.effort.level' "$1"; }
vn(){ v "$@" | jq -c 'del(.tool_input.effort)'; }

# captured effort (low) = wrong-effort control
g "$(v "$PLAN" fable)"; rc=$?
ck "plan + fable + captured effort low -> deny naming the forbidden effort" '[ $rc = 2 ] && grep -q "forbidden effort .low." "$T/e"'
g "$(v "$PLAN" sonnet)"; rc=$?
ck "plan + sonnet + captured low -> deny naming given sonnet/low and forbidden effort" '[ $rc = 2 ] && grep -q "forbidden effort .low." "$T/e" && grep -q "given model=.sonnet. effort=.low." "$T/e"'
g "$(v "$PLAN" sonnet | jq -c '.effort.level="high"|.tool_input.effort="high"')"; rc=$?
ck "derived-high plan + sonnet -> deny naming the resolved fable route" '[ $rc = 2 ] && grep -q "resolved route claude-fable-5-1/high" "$T/e"'
g "$(v "$DEF" fable)"; rc=$?
ck "default + fable -> deny naming require_permission_mode" '[ $rc = 2 ] && grep -q require_permission_mode "$T/e"'
g "$(v "$DEF" sonnet)"; rc=$?
ck "default + sonnet -> deny naming require_permission_mode and given sonnet" '[ $rc = 2 ] && grep -q require_permission_mode "$T/e" && grep -q "given model=.sonnet." "$T/e"'

# DERIVED variants: only the VALUE of top-level effort.level changes (shape kept)
dv(){ v "$PLAN" fable | jq -c --arg e "$1" '.effort.level=$e|.tool_input.effort=$e'; }
g "$(dv high)"; rc=$?
ck "derived-high plan + fable + effort.level high -> allow" '[ $rc = 0 ]'
g "$(v "$DEF" fable | jq -c '.effort.level="high"|.tool_input.effort="high"')"; rc=$?
ck "derived-high default + fable + effort.level high -> deny naming require_permission_mode" '[ $rc = 2 ] && grep -q require_permission_mode "$T/e"'
g "$(dv xhigh)"; rc=$?
ck "derived-xhigh plan + fable -> deny naming fable-launch.sh --route-request" '[ $rc = 2 ] && grep -q "fable-launch.sh --route-request" "$T/e"'

# fail closed
g "$(vn "$PLAN" fable | jq -c 'del(.effort)')"; rc=$?
ck "no effort anywhere -> deny (not explicit)" '[ $rc = 2 ] && grep -q "not explicit" "$T/e"'
g "$(dv xhigh | jq -c '.tool_input.effort="low"')"; rc=$?
ck "tool_input.effort low + top-level xhigh -> deny (tool_input wins, stderr names low)" '[ $rc = 2 ] && grep -q "effort=.low." "$T/e"'
g "$(dv low | jq -c '.tool_input.effort="high"')"; rc=$?
ck "tool_input.effort high + top-level low -> allow (tool_input wins)" '[ $rc = 0 ]'

# E1: wrong-shape effort (string, not object) must fail closed, not allow
g "$(vn "$PLAN" fable | jq -c '.effort="high"')"; rc=$?
ck "E1 effort is a string -> deny (not explicit)" '[ $rc = 2 ] && grep -q "not explicit" "$T/e"'

# E4: the unmodified captured fixtures (haiku, no governed skill) pass as-is
for fx in "$PLAN" "$DEF"; do
  g "$(cat "$fx")"; rc=$?
  ck "E4 unmodified $(basename "$fx") -> allow" '[ $rc = 0 ]'
done

# E3: agent-definition effort (tool_input.effort > project agent file > user agent file > top-level effort.level); fake files in the temp HOME/project only
PRJ="$T/proj"; mkdir -p "$H/.claude/agents" "$PRJ/.claude/agents"
af(){ printf -- '---\nname: %s\nmodel: sonnet\n%s\n---\nbody\n' "$2" "$3" >"$1"; }
av(){ vn "$PLAN" fable | jq -c --arg s "$1" --arg c "$PRJ" --arg e "$2" '.tool_input.subagent_type=$s|.cwd=$c|.effort.level=$e'; }
rmaf(){ chmod 644 "$H"/.claude/agents/* "$PRJ"/.claude/agents/* 2>/dev/null; rm -f "$H"/.claude/agents/* "$PRJ"/.claude/agents/*; }
rmaf; af "$H/.claude/agents/coder.md" coder "effort: medium"
g "$(av coder high)"; rc=$?
ck "E3a user agent effort medium + session high + fable + plan -> deny naming medium" '[ $rc = 2 ] && grep -q "effort=.medium." "$T/e"'
rmaf; af "$H/.claude/agents/coder.md" coder "effort: high"
g "$(av coder low)"; rc=$?
ck "E3b agent effort high beats session low -> allow" '[ $rc = 0 ]'
rmaf; af "$PRJ/.claude/agents/x.md" x "effort: medium"; af "$H/.claude/agents/x.md" x "effort: high"
g "$(av x high)"; rc=$?
ck "E3c project agent (medium) wins over user agent (high) -> deny" '[ $rc = 2 ] && grep -q "effort=.medium." "$T/e"'
rmaf; af "$H/.claude/agents/coder.md" coder "effort: high"; chmod 000 "$H/.claude/agents/coder.md"
if [ "$(id -u)" = 0 ] || [ -r "$H/.claude/agents/coder.md" ]; then echo "SKIP E3d unreadable agent file (root or chmod ineffective)"
else g "$(av coder high)"; rc=$?
  ck "E3d unreadable agent file -> deny unresolved" '[ $rc = 2 ] && grep -q "unresolved" "$T/e"'; fi
rmaf; printf 'name: coder\neffort: high\n---\n' >"$H/.claude/agents/coder.md"
g "$(av coder high)"; rc=$?
ck "E3e first line not --- -> deny unresolved" '[ $rc = 2 ] && grep -q "unresolved" "$T/e"'
rmaf; af "$H/.claude/agents/coder.md" coder "effort: bogus"
g "$(av coder high)"; rc=$?
ck "E3f effort bogus -> deny unresolved" '[ $rc = 2 ] && grep -q "unresolved" "$T/e"'
rmaf; af "$H/.claude/agents/coder.md" coder "effort: medium"
g "$(av coder low | jq -c '.tool_input.effort="high"')"; rc=$?
ck "E3g tool_input.effort high beats agent file medium -> allow" '[ $rc = 0 ]'
rmaf; g "$(av 'bad/../x' high)"; rc=$?
ck "E3h subagent_type with path chars -> deny subagent_type unresolved" '[ $rc = 2 ] && grep -q "subagent_type unresolved" "$T/e"'
rmaf; g "$(av general-purpose high)"; rc=$?
ck "E3i built-in (no definition file), model named, no tool_input.effort -> deny not explicit (session level not used with a model, cont6)" '[ $rc = 2 ] && grep -q "not explicit" "$T/e"'
rmaf

# E8: policy lib missing -> the fallback still denies a maxspeed spawn (guard copied alone, no lib reachable, SKILL_POLICY_LIB unset)
NL="$T/nolib"; mkdir -p "$NL/a/b/hooks" "$NL/home"; cp "$R/.claude/hooks/skill-agent-effort-guard.sh" "$NL/a/b/hooks/"
gn(){ printf '%s' "$1" | env -i PATH="$PATH" HOME="$NL/home" "$NL/a/b/hooks/skill-agent-effort-guard.sh" >"$T/o" 2>"$T/e"; }
gn "$(v "$PLAN" fable)"; rc=$?
ck "E8 lib missing + maxspeed prompt -> deny 'skill-model-policy.sh not found'" '[ $rc = 2 ] && grep -q "skill-model-policy.sh not found" "$T/e"'
gn "$(jq -c '.tool_input.prompt="reply ok"' "$PLAN")"; rc=$?
ck "E8 lib missing + plain prompt -> allow" '[ $rc = 0 ]'

# cont6 edit 1: top-level effort.level counts only when tool_input.model is empty; a named model needs tool_input.effort
g "$(dv high | jq -c 'del(.tool_input.effort)')"; rc=$?
ck "AC1 plan + fable + effort.level high + no tool_input.effort -> deny 'model/effort not explicit'" '[ $rc = 2 ] && grep -q "model/effort not explicit" "$T/e"'
g "$(dv high | jq -c 'del(.tool_input.effort)|.tool_input.model=""')"; rc=$?
ck "AC1 same payload with empty model -> deny 'model/effort not explicit' (unchanged from 5b3bb8f)" '[ $rc = 2 ] && grep -q "model/effort not explicit" "$T/e"'

# cont6 edit 2: unreadable tool_input fails closed (jq shim on a temp PATH; real jq path captured first)
RJQ="$(command -v jq)"; SH="$T/shim"; mkdir -p "$SH"
printf '#!/bin/bash\ncase "$*" in *tool_input.model*|*tool_input.effort*) exit 1;; esac\nexec "%s" "$@"\n' "$RJQ" >"$SH/jq"; chmod +x "$SH/jq"
printf '%s' "$(dv high | jq -c 'del(.tool_input.effort)')" | env -i PATH="$SH:$PATH" HOME="$H" "$R/.claude/hooks/skill-agent-effort-guard.sh" >"$T/o" 2>"$T/e"; rc=$?
ck "AC2 jq cannot read tool_input.model/effort -> rc 2 'cannot read tool_input'" '[ $rc = 2 ] && grep -q "cannot read tool_input" "$T/e"'
printf 'not json' | env -i PATH="$PATH" HOME="$H" "$R/.claude/hooks/skill-agent-effort-guard.sh" >"$T/o" 2>"$T/e"; rc=$?
ck "AC2 non-JSON stdin -> rc 2 'empty or malformed hook input'" '[ $rc = 2 ] && grep -q "empty or malformed hook input" "$T/e"'

# cont6 edit 7: model-only failure (explicit baseline effort, wrong model); expected model read from the policy file
PB=$(jq -r .skills.maxspeed.baseline "$H/.config/skill-routing/policy.json"); PM=$(jq -r --arg b "$PB" '.skills.maxspeed.routes[$b].model' "$H/.config/skill-routing/policy.json")
g "$(v "$PLAN" sonnet | jq -c --arg e "${PB##*-}" '.tool_input.effort=$e')"; rc=$?
ck "AC3 plan + sonnet + explicit baseline effort -> deny naming the policy's required model" '[ -n "$PM" ] && [ $rc = 2 ] && grep -q "resolved route $PM/${PB##*-}" "$T/e"'

# finding record: at f396753 the guard read only tool_input.effort, so the real plan fixture + fable resolved E to empty
# ("model/effort not explicit" deny); now E=low from effort.level and the resolver denies on the effort value.

echo "p=$p f=$f"; [ "$f" = 0 ] && echo "ALL PASS" || exit 1
