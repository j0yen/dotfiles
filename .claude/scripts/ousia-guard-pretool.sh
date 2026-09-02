#!/usr/bin/env bash
# PreToolUse hook: run every action-taking tool call through ousia-guard.
#
# Reads the PreToolUse JSON on stdin, translates the tool call into a World
# Ontology action document, and maps the guard's verdict onto Claude Code's
# permission decision:
#
#   guard verdict  exit  hook decision
#   -------------  ----  -------------
#   allow            0   silent (no output) — tool proceeds
#   flag            10   permissionDecision=ask  with the axiom chain as reason
#   deny            20   permissionDecision=deny with the axiom chain as reason
#   error          other permissionDecision=ask  (gate broken — surface, don't hide)
#
# Mapping. Structurally, every tool call is a BFO process that `affects` one
# BFO object (the tool input). That alone always allows. Ethical content comes
# from the operator registry at $OUSIA_PARTICIPANTS (default
# ~/.local/share/ousia/participants.json): each rule has a regex `pattern`
# tested against every string in tool_input; a hit adds its `participant`
# (with types/bears), an `edge` from the action to it (affects|harms|violates|
# removes), and optional `action_types` (e.g. "Censorship"). The guard's rule
# battery then decides.
#
# Silent no-op when ousia-guard or the built ontology is absent, so this hook
# never blocks a box that hasn't run `ousia-forge build`.
#
# Every verdict is appended to $OUSIA_VERDICT_LOG as one JSON line.
set -uo pipefail

GUARD="${OUSIA_GUARD_BIN:-$HOME/.local/bin/ousia-guard}"
OWL="${OUSIA_OWL:-$HOME/.local/share/ousia/world-ontology.owl}"
REG="${OUSIA_PARTICIPANTS:-$HOME/.local/share/ousia/participants.json}"
LOG="${OUSIA_VERDICT_LOG:-$HOME/.local/share/ousia/verdicts.jsonl}"

input=$(cat)
[ -x "$GUARD" ] && [ -f "$OWL" ] && command -v jq >/dev/null 2>&1 || exit 0

tool=$(jq -r '.tool_name // empty' <<<"$input" 2>/dev/null)
[ -n "$tool" ] || exit 0
session=$(jq -r '.session_id // "unknown"' <<<"$input" 2>/dev/null)
tool_input=$(jq -c '.tool_input // {}' <<<"$input" 2>/dev/null)
haystack=$(jq -r '[.tool_input // {} | .. | strings] | join("\n")' <<<"$input" 2>/dev/null)

reg='[]'
if [ -f "$REG" ]; then
    reg=$(jq -c '.rules // []' "$REG" 2>/dev/null || echo '[]')
fi

safe_tool=$(printf '%s' "$tool" | tr -c 'A-Za-z0-9' '_')
hash=$(printf '%s' "$tool_input" | sha256sum | cut -c1-8)
action_id="Tool_${safe_tool}_${hash}"

doc=$(jq -nc --arg id "$action_id" --arg hay "$haystack" --argjson reg "$reg" '
  ($reg | map(select((.pattern // "") as $p | $p != "" and ($hay | test($p; "m"))))) as $hits
  | {
      id: $id,
      types: (["http://purl.obolibrary.org/obo/BFO_process"] + [$hits[] | .action_types[]?] | unique),
      participants: (
        [{id: ($id + "_input"), types: ["http://purl.obolibrary.org/obo/BFO_object"]}]
        + [$hits[] | .participant | select(. != null)]
        | unique_by(.id)),
      edges: (
        [{prop: "affects", target: ($id + "_input")}]
        + [$hits[] | select(.participant != null) | {prop: (.edge // "affects"), target: .participant.id}]
        | unique)
    }' 2>&1) || {
    jq -nc --arg r "ousia-guard hook: failed to build action document: $doc" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"ask", permissionDecisionReason:$r}}'
    exit 0
}

tmp=$(mktemp "${XDG_RUNTIME_DIR:-/tmp}/ousia-action.XXXXXX.json") || exit 0
trap 'rm -f "$tmp"' EXIT
printf '%s\n' "$doc" >"$tmp"

set +e
out=$("$GUARD" check --owl "$OWL" --action "$tmp" --format json --explain 2>&1)
rc=$?
set -e

case "$rc" in
    0)  verdict=allow ;;
    10) verdict=flag ;;
    20) verdict=deny ;;
    *)  verdict=error ;;
esac

rules=""
reason=""
if [ "$verdict" = allow ] || [ "$verdict" = flag ] || [ "$verdict" = deny ]; then
    rules=$(jq -r '(.rules_fired // []) | join(",")' <<<"$out" 2>/dev/null || echo "")
    reason=$(jq -r '
        (.rules_fired // []) as $r
        | ((.justifications // [])[0].justification // []) as $j
        | "ousia-guard " + (.verdict // "?" | ascii_upcase) + " [" + ($r | join(", ")) + "]"
          + (if ($j | length) > 0 then ": " + ($j | join("  ->  ")) else "" end)
        ' <<<"$out" 2>/dev/null || echo "ousia-guard $verdict")
else
    reason="ousia-guard error (exit $rc): $(printf '%s' "$out" | head -n1)"
fi

mkdir -p "$(dirname "$LOG")" 2>/dev/null
jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg session "$session" --arg tool "$tool" \
       --arg verdict "$verdict" --arg rules "$rules" --arg id "$action_id" --argjson doc "$doc" \
       '{ts:$ts, session:$session, tool:$tool, verdict:$verdict, rules:$rules, action:$id,
         doc: (if $verdict == "allow" then null else $doc end)}' >>"$LOG" 2>/dev/null || true

emit() {
    jq -nc --arg d "$1" --arg r "$2" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:$d, permissionDecisionReason:$r}}'
}

case "$verdict" in
    allow) exit 0 ;;
    flag)  emit ask  "$reason"; exit 0 ;;
    deny)  emit deny "$reason"; exit 0 ;;
    *)     emit ask  "$reason"; exit 0 ;;
esac
