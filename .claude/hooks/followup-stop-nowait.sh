#!/usr/bin/env bash
# followup-stop-nowait.sh (A1296 package 2 repair 7, rv7 F7-1): the ONE Stop-path obligation check shared by the three P2-owned Stop hooks that touch the follow-up
# fingerprint store (followup-stop-gate.sh, seat-followups.sh stop, owed-now.sh hook). Sourced, after followup-lib.sh (fu_eval_bin).
# A Stop hook never waits on the store lock and never delivers: `followup-eval.py new --nowait` takes the lock with one non-blocking try; when another process holds it
# the Stop passes with a truthful marker (<OWED_NOW_STATE>/<sid>.stoplock, read by owed-now.sh's next prompt as STOP CHECK SKIPPED) and the unrecorded fingerprint is
# escalated by the next Stop that gets the lock. Delivery of the outbox is the existing durable consumer's job (followup-outbox-replay.timer); no Stop hook replays.
# fu_stop_new <seat> <sid> : FU_STOP_NEW = new obligations (one JSON object per line, empty when none, locked or evaluator failure); FU_STOP_LOCKED=1 when the store was busy.
#   Never blocks, never fails. An unwritable marker is not silent: a systemMessage on stdout and a line on stderr say the skipped check could not be recorded (F7-3).
#   An evaluator failure (R8-7) is not "none owed": the marker is kept and gains an `evalfail <code>` line (rc-<n> | empty | malformed | shape), never evaluator output.
fu_stop_state_dir() { printf '%s' "${OWED_NOW_STATE:-$HOME/.claude/state/owed-now}"; }
fu_stop_new() {
  local seat="$1" sid="${2:-nosid}" ev nraw rc st pl sd kf msg
  FU_STOP_NEW=""; FU_STOP_LOCKED=0
  [[ "$sid" =~ ^[A-Za-z0-9._-]+$ ]] || sid=nosid
  ev="$(fu_eval_bin)" || return 0
  sd="$(fu_stop_state_dir)"; kf="$sd/$sid.stoplock"
  nraw="$(python3 -I "$ev" new --nowait --seat "$seat" 2>/dev/null)"; rc=$?
  # R8-7: only a well-formed answer is "none owed"; a nonzero exit, empty stdout, unparsable or off-contract JSON is a failed check (st = short reason code, no evaluator text).
  if [ "$rc" -ne 0 ]; then st="rc-$rc"; elif [ -z "${nraw//[[:space:]]/}" ]; then st=empty
  else st="$(jq -rs 'if length == 1 and (.[0] | type) == "object" and (.[0].new | type) == "array" and ((.[0].locked | type) == "boolean" or (.[0].locked | type) == "null")
    then (if .[0].locked then "locked" else "ok" end) else "shape" end' <<<"$nraw" 2>/dev/null)" || st=malformed; [ -n "$st" ] || st=malformed; fi
  if [ "$st" = locked ]; then
    FU_STOP_LOCKED=1
    if ! { mkdir -p "$sd" && date +%s >"$kf"; } 2>/dev/null; then
      msg="FOLLOW-UP STOP CHECK SKIPPED (seat $seat): the follow-up store was locked, so new obligations were NOT checked, and the skip marker could not be written to $sd; this is NOT \"none owed\"."
      echo "followup-stop-nowait: $msg" >&2
      jq -nc --arg m "$msg" '{systemMessage:$m}' 2>/dev/null
    fi
  elif [ "$st" = ok ]; then
    rm -f "$kf" 2>/dev/null
    FU_STOP_NEW="$(jq -c '.new[]?' <<<"$nraw" 2>/dev/null)"
  else   # failed check: the marker is kept (a prior locked line stays) and records `evalfail <code>`, read by owed-now.sh's next prompt as STOP CHECK FAILED
    pl="$(grep -m1 -xE '[0-9]{1,12}' "$kf" 2>/dev/null)"
    if ! { mkdir -p "$sd" && printf '%s%s\n' "${pl:+$pl$'\n'}" "evalfail $st" >"$kf"; } 2>/dev/null; then
      msg="FOLLOW-UP STOP CHECK FAILED (seat $seat): the follow-up evaluator failed ($st), so new obligations were NOT checked, and the failure marker could not be written to $sd; this is NOT \"none owed\"."
      echo "followup-stop-nowait: $msg" >&2
      jq -nc --arg m "$msg" '{systemMessage:$m}' 2>/dev/null
    fi
  fi
  return 0
}
