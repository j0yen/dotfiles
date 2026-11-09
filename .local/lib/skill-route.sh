#!/usr/bin/env bash
# skill-route.sh: shell helpers over the ONE skill-routing policy + resolver (ledger A1300). Sourced by the hooks and the audit.
# Skills and phases are data in policy.json; nothing here names a skill.
_SR_HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
sr_policy_file() {
  local c
  for c in "${SKILL_ROUTE_POLICY:-}" "$_SR_HERE/../../.config/skill-routing/policy.json" "$HOME/.config/skill-routing/policy.json"; do
    [ -n "$c" ] && [ -r "$c" ] && { printf '%s' "$c"; return 0; }
  done; return 1
}
sr_resolver_file() {
  local c
  for c in "${SKILL_ROUTE_RESOLVER:-}" "$_SR_HERE/skill-route-resolve.py" "$HOME/.local/lib/skill-route-resolve.py"; do
    [ -n "$c" ] && [ -r "$c" ] && { printf '%s' "$c"; return 0; }
  done; return 1
}
# sr_governed NAME: 0 governed, 1 not governed, 2 policy unreadable/malformed (callers fail closed for skill-shaped calls only).
sr_governed() {
  local p; p=$(sr_policy_file) || return 2
  jq -e '.skills|type=="object"' "$p" >/dev/null 2>&1 || return 2
  jq -e --arg n "$1" '.skills|has($n)' "$p" >/dev/null 2>&1
}
sr_governed_names() { local p; p=$(sr_policy_file) || return 2; jq -r '.skills|keys[]' "$p" 2>/dev/null; }
# sr_resolve JSON: stdout = resolver JSON, rc 0 allowed / 2 denied. The request travels on stdin, never argv/shell.
sr_resolve() { local r; r=$(sr_resolver_file) || { echo '{"ok":false,"error":"resolver not found"}'; return 2; }
  printf '%s' "$1" | python3 -I "$r"; }
# sr_alias_model: native Agent aliases -> pinned ids
sr_alias_model() { case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in fable) echo claude-fable-5-1 ;; sonnet) echo claude-sonnet-5-5 ;; haiku) echo claude-haiku-5-5 ;; opus) echo claude-opus-5-5 ;; *) printf '%s' "$1" ;; esac; }
# sr_managed_worker SKILL: 0 when this process is a worker the managed launcher started for SKILL.
sr_managed_worker() { [ -n "${SKILL_ROUTE_TASK_ID:-}" ] && [ "${SKILL_ROUTE_SKILL:-}" = "$1" ]; }
sr_recipe() { # SKILL [ARGS]
  cat <<R
Run it through the managed launcher (it resolves the route from .config/skill-routing/policy.json, records a task-linked decision row, keeps account routing):
  1. write a request file: {"task_id":"<ledger id>","skill":"$1","decision_class":"<optional class>","evidence_refs":["ledger:<id>","file:<path>"],"escalation":{"reason":"<reason>","evidence":["ledger:<id>"]}}   (omit decision_class/escalation for the baseline route)
  2. ~/.local/bin/fable-launch.sh --route-request <file> -p "Invoke the $1 skill (Skill tool, skill: $1, args: ${2:-<args>}). Context + evidence: <paste>. Return the page path, lint result, verdict lines."
Escalations need a policy reason plus real evidence refs; there is no fallback to another provider or to Fable max.
R
}
