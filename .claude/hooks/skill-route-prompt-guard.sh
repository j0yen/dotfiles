#!/usr/bin/env bash
# skill-route-prompt-guard.sh: UserPromptSubmit (ledger A1300). A directly typed `/<governed-skill>` is expanded by the harness without a
# Skill call, so fable-skill-spawn-gate.sh never sees it. Governed skills are the keys of .config/skill-routing/policy.json.
# A typed governed slash outside the managed worker for that skill is blocked with the managed-launcher recipe; everything else passes.
# Harness blocks (<system-reminder>, <task-notification>, <cross-session-message>) are stripped first, as in analysis-skill-router.sh.
# Unreadable policy fails closed only for a prompt that starts with a slash-skill word; no-jq/no-input fails open (declared residual).
set -uo pipefail
JQ=$(command -v jq) || exit 0
INPUT=$(cat) || exit 0
[ -n "$INPUT" ] || exit 0
PROMPT=$(printf '%s' "$INPUT" | "$JQ" -r '.prompt // empty' 2>/dev/null) || exit 0
[ -n "$PROMPT" ] || exit 0
command -v perl >/dev/null 2>&1 || exit 0
PROMPT=$(printf '%s' "$PROMPT" | perl -0777 -pe 's{<(system-reminder|task-notification|cross-session-message)\b[^>]*>.*?</\1>}{}gs') || exit 0
SKILL=$(printf '%s' "$PROMPT" | sed -n '1,/./{/./{s/^[[:space:]]*\/\([A-Za-z0-9_:.-]*\)\([[:space:]].*\)\{0,1\}$/\1/p}}' | head -1)
[ -n "$SKILL" ] || exit 0
NAME=${SKILL##*:}
for _l in "${SKILL_ROUTE_LIB:-}" "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.local/lib/skill-route.sh" "$HOME/.local/lib/skill-route.sh"; do
    [ -n "$_l" ] && [ -r "$_l" ] && { . "$_l"; break; }; done
block() { "$JQ" -nc --arg r "$1" '{decision:"block",reason:$r}'; exit 0; }
if ! command -v sr_governed >/dev/null 2>&1; then
    case "$NAME" in 5whysandrhyme|wwhtbt) block "skill-route-prompt-guard: routing helpers unreadable; /$NAME is refused (fail closed). Restore .local/lib/skill-route.sh." ;; esac
    exit 0
fi
sr_governed "$NAME"; g=$?
if [ "$g" = 2 ]; then
    case "$NAME" in 5whysandrhyme|wwhtbt) block "skill-route-prompt-guard: routing policy unreadable or malformed; /$NAME is refused (fail closed). Restore .config/skill-routing/policy.json." ;; esac
    exit 0
fi
[ "$g" = 0 ] || exit 0
sr_managed_worker "$NAME" && exit 0
block "$(printf 'skill-route-prompt-guard: /%s is a governed skill; typed here it would run on this session'"'"'s model/effort. %s' "$NAME" "$(sr_recipe "$NAME")")"
