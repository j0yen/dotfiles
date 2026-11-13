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
# A skill whose policy sets require_permission_mode (maxspeed: plan) is also checked against the hook input's top-level permission_mode.
# Fails CLOSED on empty/malformed stdin (exit 2); fails open only without jq. A governed skill with no policy entry or no readable
# policy file is denied (policy-missing). model-effort-audit.sh checks the hook is wired and behaves.
set -uo pipefail
JQ=$(command -v jq) || exit 0
INPUT=$(cat) || exit 2
printf '%s' "$INPUT" | "$JQ" -e 'type=="object"' >/dev/null 2>&1 || { echo "skill-agent-effort-guard: empty or malformed hook input; refusing (fail closed)" >&2; exit 2; }
[ "$(printf '%s' "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null)" = Agent ] || exit 0
PMODE=$(printf '%s' "$INPUT" | "$JQ" -r '.permission_mode // empty' 2>/dev/null) || PMODE=""
HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
for _r in "${SKILL_ROUTE_LIB:-}" "$HERE/../../.local/lib/skill-route.sh" "$HOME/.local/lib/skill-route.sh"; do
  [ -n "$_r" ] && [ -r "$_r" ] && { . "$_r"; break; }; done
for _l in "${SKILL_POLICY_LIB:-}" "$HERE/../../.local/lib/skill-model-policy.sh" "$HOME/.local/lib/skill-model-policy.sh"; do
  [ -n "$_l" ] && [ -r "$_l" ] && { . "$_l"; break; }; done
if [ -z "${SKILL_POLICY_SKILLS:-}" ]; then echo "skill-agent-effort-guard: skill-model-policy.sh not found; refusing skill spawn (fail closed for the covered skills only)" >&2
  TEXT=$(printf '%s' "$INPUT" | "$JQ" -r '[.tool_input.prompt, .tool_input.description] | map(. // "") | join("\n")' 2>/dev/null) || exit 0
  printf '%s' "$TEXT" | grep -qiE '5whysandrhyme|wwhtbt|maxspeed' && exit 2; exit 0; fi
MODEL=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.model // empty' 2>/dev/null) || exit 0
EFFORT=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.effort // empty' 2>/dev/null) || exit 0
# The real client payload carries effort only at top-level effort.level; tool_input.effort (when present) wins.
[ -n "$EFFORT" ] || EFFORT=$(printf '%s' "$INPUT" | "$JQ" -r '.effort.level? // empty' 2>/dev/null) || { echo "skill-agent-effort-guard: cannot read effort.level; refusing (fail closed)" >&2; exit 2; }
TEXT=$(printf '%s' "$INPUT" | "$JQ" -r '[.tool_input.prompt, .tool_input.description] | map(. // "") | join("\n")' 2>/dev/null) || exit 0
M=$(printf '%s' "$MODEL" | tr '[:upper:]' '[:lower:]'); E=$(printf '%s' "$EFFORT" | tr '[:upper:]' '[:lower:]')
hit=""
for s in $SKILL_POLICY_SKILLS; do
  if printf '%s' "$TEXT" | grep -qiE "(invoke|run|use|call|launch|start|apply)[[:space:]]+(the[[:space:]]+)?(/?$s[[:space:]]+skill|skill[[:space:]]+/?$s|/$s)\b|\bskill[:=]?[[:space:]]*\"?/?$s\b|(^|[[:space:](])/$s([[:space:]).,;:]|$)|independent[^.]{0,40}review[^.]{0,80}\b$s\b|\b$s\b[^.]{0,80}independent[^.]{0,40}review"; then hit="$hit $s"
  elif printf '%s' "$M" | grep -q fable && printf '%s' "$TEXT" | grep -qiE "\b$s\b"; then hit="$hit $s"; fi
done
[ -n "$hit" ] || exit 0
command -v sr_resolve >/dev/null 2>&1 || { echo "skill-agent-effort-guard:${hit} routing helpers (skill-route.sh) not found; refusing governed skill spawn (fail closed)" >&2; exit 2; }
command -v sr_governed >/dev/null 2>&1 || { echo "skill-agent-effort-guard:${hit} skill-route.sh is too old (sr_governed missing: guard/lib install skew, install guard, lib and policy.json as one set); refusing governed skill spawn (fail closed)" >&2; exit 2; }
M=$(sr_alias_model "$M")
bad=""
# Agent-definition effort (Claude Code docs: tool_input.effort > project .claude/agents > user ~/.claude/agents > session effort.level).
# Only for governed spawns with no tool_input.effort; built-ins without a definition file fall through to effort.level.
TIEFF=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.effort? // empty' 2>/dev/null) || TIEFF=""
SUB=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.subagent_type? // empty' 2>/dev/null) || SUB=""
DEFBAD=""
if [ -z "$TIEFF" ] && [ -n "$SUB" ]; then
  if ! printf '%s' "$SUB" | grep -qE '^[A-Za-z0-9._-]+$'; then DEFBAD="subagent_type unresolved"
  else
    PCWD=$(printf '%s' "$INPUT" | "$JQ" -r '.cwd? // empty' 2>/dev/null) || PCWD=""
    DEF=""
    for _c in "${PCWD:+$PCWD/.claude/agents/$SUB.md}" "$HOME/.claude/agents/$SUB.md"; do
      [ -n "$_c" ] && { [ -e "$_c" ] || [ -L "$_c" ]; } && { DEF="$_c"; break; }; done
    if [ -n "$DEF" ]; then
      FM=$({ IFS= read -r _l1 && [ "${_l1%$'\r'}" = --- ] && awk 'NR>0{ if ($0 ~ /^---[ \t\r]*$/) {c=1; exit} print } END{ exit !c }'; } <"$DEF" 2>/dev/null) || FM="<malformed>"
      if [ "$FM" = "<malformed>" ]; then DEFBAD="agent definition $DEF unresolved"
      else
        AE=$(printf '%s\n' "$FM" | sed -n 's/^effort:[[:space:]]*//p' | head -1 | tr -d ' \t\r"'"'")
        if printf '%s\n' "$FM" | grep -q '^effort:'; then
          case "$AE" in low|medium|high|xhigh|max) EFFORT="$AE"; E="$AE";; *) DEFBAD="agent definition $DEF unresolved";; esac
        fi
      fi
    fi
  fi
fi
for s in $hit; do
  [ -n "$DEFBAD" ] && { bad="$bad $s($DEFBAD)"; continue; }
  sr_governed "$s"; _g=$?
  if [ "$_g" != 0 ]; then bad="$bad $s(policy-missing: no .skills.$s entry or unreadable policy file)"; continue; fi
  if [ -z "$M" ] || [ -z "$E" ]; then bad="$bad $s(model/effort not explicit)"; continue; fi
  req=$("$JQ" -nc --arg s "$s" --arg t "${SKILL_ROUTE_TASK_ID:-native-agent}" --arg m "$M" --arg e "$E" --arg pm "$PMODE" '{task_id:$t,skill:$s,requested:{model:$m,effort:$e}}+(if $pm=="" then {} else {permission_mode:$pm} end)')
  res=$(sr_resolve "$req") || bad="$bad $s($(printf '%s' "$res" | "$JQ" -r '.error // "denied"' 2>/dev/null))"
done
[ -z "$bad" ] && exit 0
{
  echo "skill-agent-effort-guard: governed skill spawn denied:${bad}. Native spawns may only use the skill's baseline route (given model='${MODEL:-<inherited>}' effort='${EFFORT:-<inherited>}'); max and escalated routes are not available here."
  [ "$E" = xhigh ] && echo "xhigh is not available on the native Agent path: the only justified path is fable-launch.sh --route-request with decision_class (unresolved_reasoning_gap) and evidence_refs (real ledger:/file:/pr:/run:/commit:/page: refs)."
  sr_recipe "${hit# }"
} >&2
exit 2
