#!/usr/bin/env bash
# Stop hook (follow-up loop repair, ledger ask A1307; replaces the cite-or-clear recital of D2/E): a seat (WM_SEAT rb|r7|ctl|aide) is blocked only by a NEW
# actionable obligation from the canonical ledger (followup-lib.sh fu_eval: overdue with no live claim and no structured blocker, stale claim, expired
# blocker, unreadable ledger). Each fingerprint (id|rev|kind|next_check) is delivered once, persisted under flock, with one outbox entry for the durable
# deliverer; the same state on the next Stop passes silently, and a changed rev, new id or lapsed next-check is a new fingerprint. The block carries ids plus
# the specific next action. A malformed or unreadable ledger is itself an obligation (visible, never permissive closure).
# Silent exit 0 for: no WM_SEAT, a subagent (.agent_id), a `claude -p` child that inherited WM_SEAT (seats.tsv row names another sid).
# Env: FOLLOWUP_STOP_FIRES_LOG (default ~/.local/state/followup-stop-gate/fires.log) SEATS_TABLE WM_ASKS_BIN FOLLOWUP_STATE_DIR FOLLOWUP_OUTBOX FOLLOWUP_DELIVER_CMD.
set -u
here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck disable=SC1091
. "$here/followup-lib.sh" 2>/dev/null || exit 0
LOG="${FOLLOWUP_STOP_FIRES_LOG:-$HOME/.local/state/followup-stop-gate/fires.log}"
fire() { mkdir -p "${LOG%/*}" 2>/dev/null; printf '%s | followup-stop-gate | %s\n' "$(date -Iseconds)" "$*" >>"$LOG" 2>/dev/null; }

gate() {
  local in="$1" seat="${WM_SEAT:-}" sid aid tsid new r
  case "$seat" in rb|r7|ctl|aide|ops) ;; *) return 0 ;; esac
  [ -z "${WM_HELPER:-}" ] || return 0   # A1300 E4: helper child of a ctl session carries no follow-up obligation
  command -v jq >/dev/null 2>&1 || return 0
  aid="$(jq -r '.agent_id // empty' <<<"$in" 2>/dev/null)"; [ -z "$aid" ] || return 0
  sid="$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null)"
  [[ "$sid" =~ ^[A-Za-z0-9._-]*$ ]] || return 0
  tsid="$(awk -F'\t' -v s="$seat" '$1==s && $3!="" {print $3; exit}' "${SEATS_TABLE:-$HOME/.claude/state/seats.tsv}" 2>/dev/null)"
  [ -z "$tsid" ] || [ -z "$sid" ] || [ "$tsid" = "$sid" ] || return 0
  # R4 decision (A1346): evaluator-missing visibility is CHAIN-level. owed-now.sh (same Stop chain, canonical mode default) reports it once per session; this entrypoint stays silent so one defect is not recited three times. tests/followup-evaluator-missing.test.sh pins the chain.
  new="$(fu_new_obligations "$seat")"
  fu_outbox_replay >/dev/null 2>&1 || true
  [ -n "$new" ] || return 0
  r="$(fu_block_reason "$new")"
  fire "FOLLOWUP-ESCALATED seat=$seat ids=$(jq -rs 'map(.id) | join(",")' <<<"$new")"
  if [ "${WM_DIRECTOR:-}" = hermes ]; then printf 'director=hermes report-not-block: %s\n' "$r"; else jq -nc --arg r "$r" '{decision:"block",reason:$r}'; fi
}
in="$(cat 2>/dev/null)" || exit 0
gate "$in" || true
exit 0
