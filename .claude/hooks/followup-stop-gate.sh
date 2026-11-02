#!/usr/bin/env bash
# Stop hook (parts D2 + E of the follow-up tracker, approvals #114): a seat (WM_SEAT rb|r7|ctl|aide) may not end a sweep while it owns an OVERDUE or
# ESCALATED follow-up id that the turn neither cited nor cleared. Fable 10-30: the weakest link of a follow-up counter is "no consumer".
#   cited  = the full id in this turn's assistant text, or in a Bash command of this turn that runs rb-row / wm-decide (a read verb does not count).
#   cleared = gone from `wm-decide followups` when the hook re-reads it at Stop.
#   ctl (E) is checked against EVERY seat's overdue ids, so the controller cannot ignore another seat's item; the others only against their own.
# Refusal: {"decision":"block","reason":"<one line, <= 5 ids>"}. Cap: one turn is refused at most 2 times (stop_hook_active carries the count in
#   <state dir>/count.<sid>); the third Stop passes and logs FOLLOWUP-STOP-OVERRIDE with the ids, so it never loops.
# Fail-open: followups_json failing (A absent, non-zero, non-JSON) or an unreadable transcript = allow + log FOLLOWUP-STOP-ALLOW unmeasured.
# Silent exit 0 for: no WM_SEAT, a subagent (.agent_id), a `claude -p` child that inherited WM_SEAT (seats.tsv row for the seat names another sid).
# Env: FOLLOWUP_STOP_FIRES_LOG (default ~/.local/state/followup-stop-gate/fires.log; count files live beside it) SEATS_TABLE WM_DECIDE_BIN.
set -u
here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck disable=SC1091
. "$here/followup-lib.sh" 2>/dev/null || exit 0
LOG="${FOLLOWUP_STOP_FIRES_LOG:-$HOME/.local/state/followup-stop-gate/fires.log}"
fire() { mkdir -p "${LOG%/*}" 2>/dev/null; printf '%s | followup-stop-gate | %s\n' "$(date -Iseconds)" "$*" >>"$LOG" 2>/dev/null; }

gate() {
  local in="$1" seat="${WM_SEAT:-}" sid aid sha tp tsid owner_filter j ids cited txt id n cnt cf ids5 more
  case "$seat" in rb|r7|ctl|aide) ;; *) return 0 ;; esac
  command -v jq >/dev/null 2>&1 || return 0
  aid="$(jq -r '.agent_id // empty' <<<"$in" 2>/dev/null)"; [ -z "$aid" ] || return 0
  sid="$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null)"
  [[ "$sid" =~ ^[A-Za-z0-9._-]*$ ]] || return 0
  tsid="$(awk -F'\t' -v s="$seat" '$1==s && $3!="" {print $3; exit}' "${SEATS_TABLE:-$HOME/.claude/state/seats.tsv}" 2>/dev/null)"
  [ -z "$tsid" ] || [ -z "$sid" ] || [ "$tsid" = "$sid" ] || return 0
  sha="$(jq -r '.stop_hook_active // false' <<<"$in" 2>/dev/null)"; tp="$(jq -r '.transcript_path // empty' <<<"$in" 2>/dev/null)"
  cf="${LOG%/*}/count.${sid:-nosid}"
  if [ "$sha" = true ]; then cnt="$(cat "$cf" 2>/dev/null)"; [[ "$cnt" =~ ^[0-9]+$ ]] || cnt=0; else cnt=0; rm -f "$cf"; fi
  if [ "$seat" = ctl ]; then owner_filter=""; else owner_filter="$seat"; fi
  followups_read "$owner_filter" || { fire "FOLLOWUP-STOP-ALLOW unmeasured seat=$seat ($FU_REASON)"; rm -f "$cf"; return 0; }
  j="$FU_JSON"
  ids="$(jq -r --arg o "$owner_filter" '(.ids // [])[] | select((.state=="overdue" or .state=="escalated") and ($o=="" or .owner==$o)) | .id' <<<"$j" 2>/dev/null)"
  [ -n "$ids" ] || { rm -f "$cf"; return 0; }
  if [ -z "$tp" ] || [ ! -r "$tp" ]; then fire "FOLLOWUP-STOP-ALLOW unmeasured seat=$seat (transcript unreadable)"; rm -f "$cf"; return 0; fi
  # this turn = everything after the last real user prompt (a user entry that is not only tool_results)
  txt="$(timeout 10 jq -R 'fromjson?' "$tp" 2>/dev/null | timeout 10 jq -rs '
    def isprompt: .type=="user" and ((.message.content|type)=="string" or ([.message.content[]? | select(.type=="tool_result")] | length)==0);
    . as $a | ([range(0; length) | select($a[.] | isprompt)] | last // 0) as $i
    | $a[$i:][] | select(.type=="assistant") | .message.content[]?
    | if .type=="text" then .text
      elif .type=="tool_use" then (.input.command? // empty | tostring | select(test("(^|[^[:alnum:]_.-])(rb-row[A-Za-z0-9._-]*|wm-decide)( |$)") and (test("wm-decide +(list|followups|show|get)( |$)")|not)))
      else empty end' 2>/dev/null)" || { fire "FOLLOWUP-STOP-ALLOW unmeasured seat=$seat (transcript parse failed)"; rm -f "$cf"; return 0; }
  cited=""; n=0
  while IFS= read -r id; do [ -n "$id" ] || continue
    if grep -qF -- "$id" <<<"$txt"; then continue; fi
    cited="$cited $id"; n=$((n + 1))
  done <<<"$ids"
  [ "$n" -gt 0 ] || { rm -f "$cf"; return 0; }
  ids5="$(tr ' ' '\n' <<<"$cited" | grep . | head -n 5 | paste -sd, - | sed 's/,/, /g')"; more=""; [ "$n" -gt 5 ] && more=" and $((n - 5)) more"
  if [ "$cnt" -ge 2 ]; then fire "FOLLOWUP-STOP-OVERRIDE seat=$seat n=$n ids=$(tr ' ' ',' <<<"${cited# }")"; rm -f "$cf"; return 0; fi
  echo $((cnt + 1)) >"$cf" 2>/dev/null
  fire "FOLLOWUP-STOP-REFUSED seat=$seat n=$n refusal=$((cnt + 1)) ids=$(tr ' ' ',' <<<"${cited# }")"
  jq -nc --arg r "FOLLOW-UPS OVERDUE (seat $seat): cite the full id in a row or in your final text, or clear it, before ending this sweep: $ids5$more" '{decision:"block",reason:$r}'
}
in="$(cat 2>/dev/null)" || exit 0
gate "$in" || true
exit 0
