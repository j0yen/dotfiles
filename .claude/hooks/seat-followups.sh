#!/usr/bin/env bash
# A49 D1 + D2 (follow-up tracker, Joe 10-31 10:3x PM): one seat's owed corrections, read from `wm-decide followups --json --agent <seat>`.
#   seat-followups.sh line   -> prints `FOLLOWUPS <seat>: owed N overdue M escalated E; oldest 5: <id> ...` (D1; SessionStart calls it), or
#                               `FOLLOWUPS <seat>: unknown (<reason>)` on timeout / missing binary / bad JSON. Always exit 0.
#   seat-followups.sh stop   -> Stop hook (D2): with WM_SEAT set and that seat holding overdue ids, blocks the turn end unless the turn cites one of the
#                               5 oldest overdue ids in full or carries a `FOLLOWUPS <seat> owed <n>-><n>` line. stop_hook_active true = allow (loop guard).
#                               wm-decide timeout/error = allow + a fires.log line. Every refusal is logged.
# Env: WM_SEAT, WM_FOLLOWUPS_TIMEOUT (default 8 s), SEAT_FOLLOWUPS_LOG_DIR (default ~/.local/state/seat-followups-stop).
set -u
mode="${1:-line}"; seat="${WM_SEAT:-}"
logdir="${SEAT_FOLLOWUPS_LOG_DIR:-$HOME/.local/state/seat-followups-stop}"
flog() { mkdir -p "$logdir" 2>/dev/null; printf '%s | %s | %s\n' "$(date -Is)" "${seat:-none}" "$*" >>"$logdir/fires.log" 2>/dev/null; return 0; }
fetch() {  # sets J (json) and WHY (reason, empty when ok)
  J=""; WHY=""
  command -v wm-decide >/dev/null 2>&1 || { WHY="wm-decide not found"; return 1; }
  command -v jq >/dev/null 2>&1 || { WHY="jq not found"; return 1; }
  J="$(timeout "${WM_FOLLOWUPS_TIMEOUT:-8}" wm-decide followups --json --agent "$seat" 2>/dev/null)"; local rc=$?
  [ "$rc" = 124 ] && { WHY="timeout"; return 1; }
  [ "$rc" = 0 ] || { WHY="wm-decide rc=$rc"; return 1; }
  jq -e '.owed != null and (.ids | type == "array")' <<<"$J" >/dev/null 2>&1 || { WHY="bad JSON"; return 1; }
  return 0
}
oldest5() { jq -r '[.ids[] | select(.state=="overdue" or .state=="escalated")] | sort_by(-.age_h) | .[0:5][] | .id' <<<"$J" 2>/dev/null; }
emit() {  # $1 = reason; WM_DIRECTOR=hermes reports one line and exits 0, otherwise a block decision
  if [ "${WM_DIRECTOR:-}" = hermes ]; then printf 'director=hermes report-not-block: %s\n' "$(tr '\n' ' ' <<<"$1")"; else jq -nc --arg r "$1" '{decision:"block",reason:$r}'; fi
}
shared_new() {  # A1346: the shared evaluator (one fingerprint file with owed-now.sh); blocks only on a NEW obligation, never an unchanged delivered one
  local ev new reason   # R4 (A1346): a missing evaluator returns silently here by design; owed-now.sh reports it once per session on the same Stop chain (tests/followup-evaluator-missing.test.sh)
  ev="$(. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/followup-lib.sh" 2>/dev/null; fu_eval_bin)" && [ -n "$ev" ] || return 0
  . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/followup-lib.sh"
  new="$(fu_new_obligations "$seat")"; fu_outbox_replay
  if jq -e 'select(.kind=="ledger-unreadable")' <<<"$new" >/dev/null 2>&1; then flog "ALLOW ledger unreadable: $(jq -r 'select(.kind=="ledger-unreadable") | .detail' <<<"$new" | head -1)"; new="$(jq -c 'select(.kind!="ledger-unreadable")' <<<"$new")"; fi   # an unreadable ledger fails open here and is logged; the other consumers report it
  [ -n "$new" ] || return 0
  reason="$(fu_block_reason "$new")"; flog "BLOCK-NEW $(jq -r '.id' <<<"$new" | paste -sd, -)"
  emit "$reason"
}
case "$mode" in
line)
  [ -n "$seat" ] || exit 0
  if fetch; then
    ids="$(oldest5 | paste -sd' ' -)"
    echo "FOLLOWUPS $seat: owed $(jq -r '.owed' <<<"$J") overdue $(jq -r '.overdue' <<<"$J") escalated $(jq -r '.escalated' <<<"$J"); oldest 5: ${ids:-none}"
  else
    echo "FOLLOWUPS $seat: unknown ($WHY)"
  fi
  exit 0 ;;
stop)
  [ -n "$seat" ] || exit 0
  in="$(cat 2>/dev/null)"
  command -v jq >/dev/null 2>&1 || exit 0
  [ "$(jq -r '.stop_hook_active // false' <<<"$in" 2>/dev/null)" = true ] && exit 0
  if ! fetch; then flog "ALLOW wm-decide unavailable: $WHY"; exit 0; fi
  ids="$(oldest5)"
  if [ -n "$ids" ]; then
    tp="$(jq -r '.transcript_path // empty' <<<"$in" 2>/dev/null)"
    turn=""
    if [ -n "$tp" ] && [ -r "$tp" ]; then
      # the turn = everything after the last real user message (a user entry that is not just tool results)
      turn="$(jq -rs '
        def real: .type=="user" and ((.message.content|type)=="string" or any(.message.content[]?; .type!="tool_result"));
        ([to_entries[] | select(.value|real) | .key] | last // -1) as $i | .[($i+1):] | map(tostring) | join("\n")' "$tp" 2>/dev/null)"
    fi
    while IFS= read -r id; do [ -n "$id" ] && grep -qF -- "$id" <<<"$turn" && exit 0; done <<<"$ids"
    grep -Eq "FOLLOWUPS $seat owed [0-9]+->[0-9]+" <<<"$turn" && exit 0
  fi
  shared_new   # the shared evaluator blocks once per fingerprint; an unchanged owed id is never recited again
  exit 0 ;;
*) echo "usage: seat-followups.sh line|stop" >&2; exit 0 ;;
esac
