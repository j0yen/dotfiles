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
v(){ jq -c --arg m "$2" --arg p "$MS" '.tool_input.model=$m|.tool_input.prompt=$p|.tool_input.subagent_type="general-purpose"' "$1"; }

# captured effort (low) = wrong-effort control
g "$(v "$PLAN" fable)"; rc=$?
ck "plan + fable + captured effort low -> deny naming the forbidden effort" '[ $rc = 2 ] && grep -q "forbidden effort .low." "$T/e"'
g "$(v "$PLAN" sonnet)"; rc=$?
ck "plan + sonnet + captured low -> deny naming given sonnet/low and forbidden effort" '[ $rc = 2 ] && grep -q "forbidden effort .low." "$T/e" && grep -q "given model=.sonnet. effort=.low." "$T/e"'
g "$(v "$PLAN" sonnet | jq -c '.effort.level="high"')"; rc=$?
ck "derived-high plan + sonnet -> deny naming the resolved fable route" '[ $rc = 2 ] && grep -q "resolved route claude-fable-5-1/high" "$T/e"'
g "$(v "$DEF" fable)"; rc=$?
ck "default + fable -> deny naming require_permission_mode" '[ $rc = 2 ] && grep -q require_permission_mode "$T/e"'
g "$(v "$DEF" sonnet)"; rc=$?
ck "default + sonnet -> deny naming require_permission_mode and given sonnet" '[ $rc = 2 ] && grep -q require_permission_mode "$T/e" && grep -q "given model=.sonnet." "$T/e"'

# DERIVED variants: only the VALUE of top-level effort.level changes (shape kept)
dv(){ v "$PLAN" fable | jq -c --arg e "$1" '.effort.level=$e'; }
g "$(dv high)"; rc=$?
ck "derived-high plan + fable + effort.level high -> allow" '[ $rc = 0 ]'
g "$(v "$DEF" fable | jq -c '.effort.level="high"')"; rc=$?
ck "derived-high default + fable + effort.level high -> deny naming require_permission_mode" '[ $rc = 2 ] && grep -q require_permission_mode "$T/e"'
g "$(dv xhigh)"; rc=$?
ck "derived-xhigh plan + fable -> deny naming fable-launch.sh --route-request" '[ $rc = 2 ] && grep -q "fable-launch.sh --route-request" "$T/e"'

# fail closed
g "$(v "$PLAN" fable | jq -c 'del(.effort)')"; rc=$?
ck "no effort anywhere -> deny (not explicit)" '[ $rc = 2 ] && grep -q "not explicit" "$T/e"'
g "$(dv xhigh | jq -c '.tool_input.effort="low"')"; rc=$?
ck "tool_input.effort low + top-level xhigh -> deny (tool_input wins, stderr names low)" '[ $rc = 2 ] && grep -q "effort=.low." "$T/e"'
g "$(dv low | jq -c '.tool_input.effort="high"')"; rc=$?
ck "tool_input.effort high + top-level low -> allow (tool_input wins)" '[ $rc = 0 ]'

# E1: wrong-shape effort (string, not object) must fail closed, not allow
g "$(v "$PLAN" fable | jq -c '.effort="high"')"; rc=$?
ck "E1 effort is a string -> deny (not explicit)" '[ $rc = 2 ] && grep -q "not explicit" "$T/e"'

# E4: the unmodified captured fixtures (haiku, no governed skill) pass as-is
for fx in "$PLAN" "$DEF"; do
  g "$(cat "$fx")"; rc=$?
  ck "E4 unmodified $(basename "$fx") -> allow" '[ $rc = 0 ]'
done

# finding record: at f396753 the guard read only tool_input.effort, so the real plan fixture + fable resolved E to empty
# ("model/effort not explicit" deny); now E=low from effort.level and the resolver denies on the effort value.

echo "p=$p f=$f"; [ "$f" = 0 ] && echo "ALL PASS" || exit 1
