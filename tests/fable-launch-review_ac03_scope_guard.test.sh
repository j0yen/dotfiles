#!/usr/bin/env bash
# fable-launch-review AC 3: a live reviewer refuses another reviewer of the same scope_id (73), admits another scope, serially and at once (R4, R5, R11).
# Run alone: bash tests/fable-launch-review_ac03_scope_guard.test.sh
. "$(dirname "$0")/fable-launch-review_lib.sh"
flr_begin
SR="$(uuid)"; flr_req h A3 "$FX/happy.sha256"; flr_run h h --session-id "$SR" -p x; S="$(flr_get h .scope_id)"
ck "reviewer launches with scope_id S" '[ "$FLR_RC" = 0 ] && [ "$(flr_get h .role)" = review ] && [ ${#S} = 64 ]'
flr_live "$SR"; LR=$FLR_LIVE
for m in prefixed reordered dupline; do
  flr_req "$m" A3 "$FX/$m.sha256"; flr_run "$m" "$m" --session-id "$(uuid)" -p x
  ck "same scope via $m beside the live reviewer: 73, nothing started" '[ "$FLR_RC" = 73 ] && flr_spy_empty $m && [ "$(flr_count $m launch)" = 0 ]'
  ck "same scope via $m: denied row names S and the live session, carries role review and S" '[ "$(flr_count $m denied)" = 1 ] && flr_get $m .reasons | grep -qF "$S" && flr_get $m .reasons | grep -qF "$SR" && [ "$(flr_get $m "[.role,.scope_id]|join(\",\")")" = "review,$S" ]'
done
for m in single dupname; do
  flr_req "o$m" A3 "$FX/$m.sha256"; flr_run "o$m" "o$m" --session-id "$(uuid)" -p x
  ck "another scope ($m) beside the live reviewer runs with a distinct scope_id" '[ "$FLR_RC" = 0 ] && ! flr_spy_empty o$m && [ "$(flr_get o$m .role)" = review ] && [ -n "$(flr_get o$m .scope_id)" ] && [ "$(flr_get o$m .scope_id)" != "$S" ]'
done
flr_kill "$LR"
# Two same-scope requests with distinct pre-drawn ids started at once: exactly one launch and one denied row.
CA="$(uuid)"; CB="$(uuid)"; flr_req ca A3C "$FX/happy.sha256"; flr_req cb A3C "$FX/prefixed.sha256"
before="$(wc -l <"$DEC")"
FLR_SPY_SLEEP=8 flr_bg ca ca --session-id "$CA" -p x; FLR_SPY_SLEEP=8 flr_bg cb cb --session-id "$CB" -p x
wait "${FLR_BG[@]: -2}" 2>/dev/null
tail -n +"$((before+1))" "$DEC" >"$T/new.conc"
rcs="$(cat "$T/rc.ca" "$T/rc.cb" | sort | tr '\n' ' ')"
ck "concurrent same-scope launches: one exit 0 and one exit 73 (got $rcs)" '[ "$rcs" = "0 73 " ]'
ck "concurrent same-scope launches: one launch row and one denied row for the task" '[ "$(flr_count conc launch)" = 1 ] && [ "$(flr_count conc denied)" = 1 ]'
ck "concurrent denied row names S and the session that won" 'w="$(flr_get conc "select(.decision==\"launch\") | .session")"; flr_get conc "select(.decision==\"denied\") | .reasons" | grep -qF "$w" && flr_get conc "select(.decision==\"denied\") | .reasons" | grep -qF "$S"'
flr_end
