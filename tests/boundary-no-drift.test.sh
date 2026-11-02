#!/usr/bin/env bash
# boundary-no-drift: gen/boundary-rules.json vs CLAUDE.md and the installed files (A237, L4),
# plus the boundary-gate.sh evaluator on the classifier rules.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tbl="$here/gen/boundary-rules.json"
md="$here/.claude/CLAUDE.md"
gate="$here/.claude/hooks/boundary-gate.sh"
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# 1. every installed rule resolves to an existing file
while IFS=$'\t' read -r id hook; do
    [ -e "$here/$hook" ] && ok "installed $id -> $hook" || bad "installed $id: missing $hook"
done < <(jq -r '.rules[] | select(.status=="installed") | [.id,.hook] | @tsv' "$tbl")

# 2. every rule's CLAUDE.md marker still appears there (rule and text do not drift apart)
while IFS=$'\t' read -r id m; do
    grep -qF -- "$m" "$md" && ok "marker $id '$m'" || bad "marker $id: '$m' not in CLAUDE.md"
done < <(jq -r '.rules[] | [.id,.claude_md] | @tsv' "$tbl")

# 3. every *.sh CLAUDE.md names resolves to a rule marker or the exempt list
for n in $(grep -o -E '[a-z0-9-]+\.sh' "$md" | sort -u); do
    if jq -e --arg n "$n" '[.rules[].claude_md | contains($n)] | any' "$tbl" >/dev/null \
        || jq -e --arg n "$n" '.exempt.names | index($n)' "$tbl" >/dev/null; then ok "named $n"; else bad "named $n: no rule or exempt entry"; fi
done

# 4. spec/judgment rules stay listed (claude_operated), reported not hidden
echo "claude_operated: $(jq -r '[.rules[] | select(.status!="installed") | .id] | join(",")' "$tbl")"

# 5. evaluator
run() { # want(deny|block|allow) event env-assignment json
    local want="$1" ev="$2" envv="$3" js="$4" out got
    out=$(printf '%s' "$js" | env $envv "$gate" "$ev")
    if printf '%s' "$out" | grep -q '"deny"'; then got=deny; elif printf '%s' "$out" | grep -q '"block"'; then got=block; elif [ -z "$out" ]; then got=allow; else got="odd:$out"; fi
    [ "$got" = "$want" ] && ok "gate $want $ev $envv" || bad "gate want $want got $got ($ev $envv $js)"
}
run deny PreToolUse WM_SEAT=rb '{"tool_name":"AskUserQuestion"}'
run allow PreToolUse WM_SEAT= '{"tool_name":"AskUserQuestion"}'
run allow PreToolUse WM_SEAT=rb '{"tool_name":"Bash"}'
run block Stop WM_SEAT=rb '{"last_assistant_message":"Done. Do you want me to merge it?"}'
run allow Stop WM_SEAT=rb '{"last_assistant_message":"Merged and logged."}'
run block Stop WM_SEAT=rb '{"last_assistant_message":"I will check this at noon."}'
run allow Stop WM_SEAT=rb '{"last_assistant_message":"I will check this at noon (P41)."}'
run allow Stop WM_SEAT=rb '{"stop_hook_active":true,"last_assistant_message":"I will do it."}'
run allow Stop WM_SEAT= '{"last_assistant_message":"I will do it."}'
[ "$fail" -eq 0 ] && echo "ALL PASS boundary-no-drift" || { echo "FAILED boundary-no-drift"; exit 1; }
