#!/usr/bin/env bash
# followup-stop-nowait.sh (A1296 package 2 repair 7, rv7 F7-1): the ONE Stop-path obligation check shared by the three P2-owned Stop hooks that touch the follow-up
# fingerprint store (followup-stop-gate.sh, seat-followups.sh stop, owed-now.sh hook). Sourced, after followup-lib.sh (fu_eval_bin).
# A Stop hook never waits on the store lock and never delivers: `followup-eval.py new --nowait` takes the lock with one non-blocking try; when another process holds it
# the Stop passes with a truthful marker (<OWED_NOW_STATE>/<sid>.stoplock, read by owed-now.sh's next prompt as STOP CHECK SKIPPED) and the unrecorded fingerprint is
# escalated by the next Stop that gets the lock. Delivery of the outbox is the existing durable consumer's job (followup-outbox-replay.timer); no Stop hook replays.
# fu_stop_new <seat> <sid> : FU_STOP_NEW = new obligations (one JSON object per line, empty when none, locked or evaluator failure); FU_STOP_LOCKED=1 when the store was busy.
#   Never blocks, never fails. An unwritable marker is not silent: a systemMessage on stdout and a line on stderr say the skipped check could not be recorded (F7-3).
fu_stop_state_dir() { printf '%s' "${OWED_NOW_STATE:-$HOME/.claude/state/owed-now}"; }
fu_stop_new() {
  local seat="$1" sid="${2:-nosid}" ev nraw sd kf msg
  FU_STOP_NEW=""; FU_STOP_LOCKED=0
  [[ "$sid" =~ ^[A-Za-z0-9._-]+$ ]] || sid=nosid
  ev="$(fu_eval_bin)" || return 0
  sd="$(fu_stop_state_dir)"; kf="$sd/$sid.stoplock"
  nraw="$(python3 -I "$ev" new --nowait --seat "$seat" 2>/dev/null)"
  if [ "$(jq -r '.locked // false' <<<"$nraw" 2>/dev/null)" = true ]; then
    FU_STOP_LOCKED=1
    if ! { mkdir -p "$sd" && date +%s >"$kf"; } 2>/dev/null; then
      msg="FOLLOW-UP STOP CHECK SKIPPED (seat $seat): the follow-up store was locked, so new obligations were NOT checked, and the skip marker could not be written to $sd; this is NOT \"none owed\"."
      echo "followup-stop-nowait: $msg" >&2
      jq -nc --arg m "$msg" '{systemMessage:$m}' 2>/dev/null
    fi
  else
    rm -f "$kf" 2>/dev/null
    FU_STOP_NEW="$(jq -c '.new[]?' <<<"$nraw" 2>/dev/null)"
  fi
  return 0
}
