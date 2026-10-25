#!/usr/bin/env bash
# seat-turn-budget.sh: PreToolUse hook for operator-seat `claude -p` turns (five-whys 2026-10-24 r7-cap-killed-turn-minutes, mechanism 1 as amended).
# seat-tick.sh exports SEAT_TURN_DEADLINE (epoch s) = turn start + cap - 900 s. Unset = not a seat turn: do nothing (exit 0, no output).
# When set, deny:
#   - any tool call once now >= deadline: "turn budget spent: print STATUS and end"  (the turn then ends exit 0 instead of a cap kill)
#   - an Agent/Task spawn within 600 s of the deadline (a spawned agent outliving the model's last word keeps the process up)
#   - an Agent/Task of subagent_type coder / coder-opus in a seat turn at all (coders run as systemd-run units, rb-run-coder.sh)
#   - a Bash whose explicit `timeout N` (command text or the tool's timeout field) exceeds the remaining budget
# Fails OPEN on any parse error. SEAT_TURN_NOW overrides the clock (tests only). `--selftest` runs the checks.
set -uo pipefail

decide() {   # decide <input-json> -> prints a deny JSON or nothing
  local in="$1" now dl rem tool sub cmd tmo_ms n u secs
  dl="${SEAT_TURN_DEADLINE:-}"
  [[ "$dl" =~ ^-?[0-9]+$ ]] || return 0
  now="${SEAT_TURN_NOW:-$(date +%s)}"; rem=$(( dl - now ))
  tool="$(jq -r '.tool_name // empty' <<<"$in" 2>/dev/null)" || return 0
  deny() { jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; }
  if [ "$rem" -le 0 ]; then deny "turn budget spent: print STATUS and end"; return 0; fi
  case "$tool" in
    Agent|Task)
      sub="$(jq -r '.tool_input.subagent_type // empty' <<<"$in" 2>/dev/null)"
      case "$sub" in coder|coder-opus) deny "coder agents are not spawned inside a seat turn: run the coder as a systemd-run --user unit (rb-run-coder.sh)"; return 0 ;; esac
      if [ "$rem" -le 600 ]; then deny "turn budget: ${rem}s left, no new Agent within 600 s of the deadline: print STATUS and end"; return 0; fi ;;
    Bash)
      cmd="$(jq -r '.tool_input.command // empty' <<<"$in" 2>/dev/null)"
      tmo_ms="$(jq -r '.tool_input.timeout // empty' <<<"$in" 2>/dev/null)"
      if [[ "$tmo_ms" =~ ^[0-9]+$ ]] && [ $(( tmo_ms / 1000 )) -gt "$rem" ]; then deny "Bash timeout $(( tmo_ms / 1000 ))s exceeds the ${rem}s left in this turn's budget"; return 0; fi
      # explicit `timeout [opts] N[smhd]` at COMMAND POSITION (start, or after ; && || | ( , optionally after sudo/env/VAR=x): a quoted `echo "timeout 3600"` is not a call
      while read -r n u; do
        [ -n "$n" ] || continue
        case "$u" in m) secs=$(( n * 60 )) ;; h) secs=$(( n * 3600 )) ;; d) secs=$(( n * 86400 )) ;; *) secs="$n" ;; esac
        if [ "$secs" -gt "$rem" ]; then deny "Bash 'timeout $n$u' exceeds the ${rem}s left in this turn's budget"; return 0; fi
      done < <(grep -oE '(^|[;&|(])[[:space:]]*((sudo|env)[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*timeout([[:space:]]+-[-A-Za-z]+(=[^[:space:]]+)?([[:space:]]+[0-9]+[smhd]?)?)*[[:space:]]+[0-9]+[smhd]?' <<<"$cmd" 2>/dev/null \
                 | sed -E 's/.*[[:space:]]([0-9]+)([smhd]?)$/\1 \2/') ;;
  esac
  return 0
}

if [ "${1:-}" = "--selftest" ]; then
  fail=0; chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
  export SEAT_TURN_NOW=1000
  mk() { jq -nc --arg t "$1" --argjson i "$2" '{tool_name:$t, tool_input:$i}'; }
  unset SEAT_TURN_DEADLINE; [ -z "$(decide "$(mk Bash '{"command":"ls"}')")" ]; chk "no deadline: allow" $?
  export SEAT_TURN_DEADLINE=5000
  [ -z "$(decide "$(mk Bash '{"command":"ls"}')")" ]; chk "plenty left: Bash allow" $?
  [ -z "$(decide "$(mk Agent '{"subagent_type":"verifier"}')")" ]; chk "plenty left: verifier Agent allow" $?
  decide "$(mk Agent '{"subagent_type":"coder"}')" | grep -q deny; chk "coder Agent deny" $?
  decide "$(mk Agent '{"subagent_type":"coder-opus"}')" | grep -q deny; chk "coder-opus Agent deny" $?
  SEAT_TURN_DEADLINE=1500 decide "$(mk Agent '{"subagent_type":"verifier"}')" | grep -q deny; chk "Agent within 600 s of deadline deny" $?
  decide "$(mk Bash '{"command":"timeout 99999 sleep 1"}')" | grep -q deny; chk "Bash timeout 99999 deny" $?
  decide "$(mk Bash '{"command":"echo hi; timeout -k 5 2h make"}')" | grep -q deny; chk "Bash timeout -k 5 2h deny" $?
  decide "$(mk Bash '{"command":"ls","timeout":5000000}')" | grep -q deny; chk "Bash tool timeout field 5000000 ms deny" $?
  [ -z "$(decide "$(mk Bash '{"command":"timeout 60 ls"}')")" ]; chk "Bash timeout 60 allow" $?
  [ -z "$(decide "$(mk Bash '{"command":"echo \"timeout 99999\""}')")" ]; chk "quoted timeout 99999 allow" $?
  decide "$(mk Bash '{"command":"sudo timeout 99999 cmd"}')" | grep -q deny; chk "sudo timeout 99999 deny" $?
  SEAT_TURN_NOW=5000 decide "$(mk Read '{}')" | grep -q 'turn budget spent: print STATUS and end'; chk "any tool at the deadline deny" $?
  SEAT_TURN_NOW=6000 decide "$(mk Bash '{"command":"ls"}')" | grep -q 'turn budget spent'; chk "any tool past the deadline deny" $?
  [ "$fail" = 0 ] && echo "selftest: PASS" || echo "selftest: FAIL"; exit "$fail"
fi

[ -n "${SEAT_TURN_DEADLINE:-}" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
INPUT="$(cat)" || exit 0
[ -n "$INPUT" ] || exit 0
decide "$INPUT"
exit 0
