#!/usr/bin/env bash
# skill-agent-effort-guard.sh — PreToolUse (Agent): a native spawn that runs a GOVERNED skill workflow (synthesis or independent
# review) must pass an explicit model + effort equal to that skill's BASELINE route in .config/skill-routing/policy.json
# (resolved by skill-route-resolve.py, A1300). Missing/inherited, other-model, other-effort, max and escalated routes are denied
# (exit 2, managed-launcher recipe on stderr): escalations need structured reason + evidence, which only
# fable-launch.sh --route-request carries. The Fable account safeguard stays in fable-native-agent-guard.sh.
# Scope: the skills in skill-model-policy.sh (the audit checks they match policy.json). Other Agent spawns, dream, plain sessions: untouched.
# Trigger (STRONG patterns only, so a cheap scout that merely names the page is not caught):
#   "invoke/run/use/call ... <skill>", "skill: <skill>", "skill <skill>", "/<skill>" as a slash command, or "independent ... review"
#   next to a skill name. A Fable-model spawn that names the skill at all is also covered.
# Fails OPEN on malformed input / no jq (a hook must not wedge the session); model-effort-audit.sh checks the hook is wired and behaves.
set -uo pipefail
JQ=$(command -v jq) || exit 0
INPUT=$(cat) || exit 0
[ "$(printf '%s' "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null)" = Agent ] || exit 0
HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
for _r in "${SKILL_ROUTE_LIB:-}" "$HERE/../../.local/lib/skill-route.sh" "$HOME/.local/lib/skill-route.sh"; do
  [ -n "$_r" ] && [ -r "$_r" ] && { . "$_r"; break; }; done
for _l in "${SKILL_POLICY_LIB:-}" "$HERE/../../.local/lib/skill-model-policy.sh" "$HOME/.local/lib/skill-model-policy.sh"; do
  [ -n "$_l" ] && [ -r "$_l" ] && { . "$_l"; break; }; done
if [ -z "${SKILL_POLICY_EFFORT:-}" ]; then echo "skill-agent-effort-guard: skill-model-policy.sh not found; refusing skill spawn (fail closed for the covered skills only)" >&2
  TEXT=$(printf '%s' "$INPUT" | "$JQ" -r '[.tool_input.prompt, .tool_input.description] | map(. // "") | join("\n")' 2>/dev/null) || exit 0
  printf '%s' "$TEXT" | grep -qiE '5whysandrhyme|wwhtbt' && exit 2; exit 0; fi
MODEL=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.model // empty' 2>/dev/null) || exit 0
EFFORT=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.effort // empty' 2>/dev/null) || exit 0
TEXT=$(printf '%s' "$INPUT" | "$JQ" -r '[.tool_input.prompt, .tool_input.description] | map(. // "") | join("\n")' 2>/dev/null) || exit 0
M=$(printf '%s' "$MODEL" | tr '[:upper:]' '[:lower:]'); E=$(printf '%s' "$EFFORT" | tr '[:upper:]' '[:lower:]')
hit=""
for s in $SKILL_POLICY_SKILLS; do
  if printf '%s' "$TEXT" | grep -qiE "(invoke|run|use|call|launch|start|apply)[[:space:]]+(the[[:space:]]+)?(/?$s[[:space:]]+skill|skill[[:space:]]+/?$s|/$s)\b|\bskill[:=]?[[:space:]]*\"?/?$s\b|(^|[[:space:](])/$s([[:space:]).,;:]|$)|independent[^.]{0,40}review[^.]{0,80}\b$s\b|\b$s\b[^.]{0,80}independent[^.]{0,40}review"; then hit="$hit $s"
  elif printf '%s' "$M" | grep -q fable && printf '%s' "$TEXT" | grep -qiE "\b$s\b"; then hit="$hit $s"; fi
done
[ -n "$hit" ] || exit 0
command -v sr_resolve >/dev/null 2>&1 || { echo "skill-agent-effort-guard:${hit} routing helpers (skill-route.sh) not found; refusing governed skill spawn (fail closed)" >&2; exit 2; }
M=$(sr_alias_model "$M")
bad=""
for s in $hit; do
  if [ -z "$M" ] || [ -z "$E" ]; then bad="$bad $s(model/effort not explicit)"; continue; fi
  req=$("$JQ" -nc --arg s "$s" --arg t "${SKILL_ROUTE_TASK_ID:-native-agent}" --arg m "$M" --arg e "$E" '{task_id:$t,skill:$s,requested:{model:$m,effort:$e}}')
  res=$(sr_resolve "$req") || bad="$bad $s($(printf '%s' "$res" | "$JQ" -r '.error // "denied"' 2>/dev/null))"
done
[ -z "$bad" ] && exit 0
{
  echo "skill-agent-effort-guard: governed skill spawn denied:${bad}. Native spawns may only use the skill's baseline route (given model='${MODEL:-<inherited>}' effort='${EFFORT:-<inherited>}'); max and escalated routes are not available here."
  sr_recipe "${hit# }"
} >&2
exit 2
