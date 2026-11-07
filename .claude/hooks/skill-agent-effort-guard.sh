#!/usr/bin/env bash
# skill-agent-effort-guard.sh — PreToolUse (Agent): a spawn that runs the /5whysandrhyme or /wwhtbt workflow (synthesis or
# independent review) must pass model=fable (claude-fable-5-1) AND effort=xhigh. Missing, inherited, other-model or other-effort
# spawns are denied (exit 2, recipe on stderr). effort=max passes only with a ledger-backed exception file:
#   ${MEA_MAX_EXCEPTION:-~/.config/wm-decide/skill-effort-max-exception.json}
#   {"skill":"5whysandrhyme|wwhtbt|*","ledger":"<row id present in open-asks.tsv>","gap":"<the unresolved gap>","expires":"<ISO time in the future>"}
# Scope: only the two skills in skill-model-policy.sh. Other Agent spawns (Fable included), dream, plain sessions: untouched (exit 0).
# Trigger (STRONG patterns only, so a cheap scout that merely names the page is not caught):
#   "invoke/run/use/call ... <skill>", "skill: <skill>", "skill <skill>", "/<skill>" as a slash command, or "independent ... review"
#   next to a skill name. A Fable-model spawn that names the skill at all is also covered.
# Fails OPEN on malformed input / no jq (a hook must not wedge the session); model-effort-audit.sh checks the hook is wired and behaves.
set -uo pipefail
JQ=$(command -v jq) || exit 0
INPUT=$(cat) || exit 0
[ "$(printf '%s' "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null)" = Agent ] || exit 0
HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
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
model_ok=0; case "$M" in fable|"$SKILL_POLICY_MODEL") model_ok=1 ;; esac
exc_ok=0
if [ "$E" = max ] && [ "$model_ok" = 1 ]; then
  EXC="${MEA_MAX_EXCEPTION:-$HOME/.config/wm-decide/skill-effort-max-exception.json}"
  ASKS="${MEA_OPEN_ASKS:-$HOME/.cache/aide/open-asks.tsv}"
  if [ -r "$EXC" ]; then
    led=$("$JQ" -r '.ledger // empty' "$EXC" 2>/dev/null); gap=$("$JQ" -r '.gap // empty' "$EXC" 2>/dev/null)
    exp=$("$JQ" -r '.expires // empty' "$EXC" 2>/dev/null); sk=$("$JQ" -r '.skill // empty' "$EXC" 2>/dev/null)
    exp_s=$(date -d "$exp" +%s 2>/dev/null || echo 0)
    ok=1
    [[ "$led" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$ ]] || ok=0
    [ -n "$gap" ] && [ "$exp_s" -gt "$(date +%s)" ] || ok=0
    [ "$ok" = 1 ] && [ -r "$ASKS" ] && grep -qF -- "$led" "$ASKS" || ok=0
    if [ "$ok" = 1 ]; then for s in $hit; do [ "$sk" = "*" ] || [ "$sk" = "$s" ] || ok=0; done; fi
    exc_ok=$ok
  fi
fi
if [ "$model_ok" = 1 ] && { [ "$E" = "$SKILL_POLICY_EFFORT" ] || [ "$exc_ok" = 1 ]; }; then exit 0; fi
{
  echo "skill-agent-effort-guard:${hit} runs on model=fable ($SKILL_POLICY_MODEL) effort=$SKILL_POLICY_EFFORT for synthesis AND independent review; got model='${MODEL:-<inherited>}' effort='${EFFORT:-<inherited>}'."
  [ "$E" = max ] && echo "max is allowed only with a ledger-backed exception file (${MEA_MAX_EXCEPTION:-~/.config/wm-decide/skill-effort-max-exception.json}: skill, ledger row present in open-asks.tsv, gap, future expires)."
  echo "Re-issue: Agent(subagent_type=general-purpose, model=fable, effort=$SKILL_POLICY_EFFORT, prompt=...)"
} >&2
exit 2
