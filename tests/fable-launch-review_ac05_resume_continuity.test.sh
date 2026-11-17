#!/usr/bin/env bash
# fable-launch-review AC 5: a resume keeps the session's recorded role and scope_id (R6), alone and beside --session-id, under its task or another.
# Amended by A1300 FFDR spec r2 (F6): a review that completed is not resumed (unchanged-review-replay); resumes after a non-clean end continue.
# Run alone: bash tests/fable-launch-review_ac05_resume_continuity.test.sh
. "$(dirname "$0")/fable-launch-review_lib.sh"
flr_begin
flr_req au A5; flr_run a au -p x; SA="$(flr_get a .session)"
SR="$(uuid)"; flr_req rh A5 "$FX/happy.sha256"; flr_run r rh --session-id "$SR" -p x; S="$(flr_get r .scope_id)"
ck "setup: author and reviewer sessions launched" '[ "$(flr_get a .role)" = author ] && [ "$(flr_get r .role)" = review ] && [ ${#S} = 64 ]'
differs(){ # NAME: 64, the R6 denied row, nothing started
  dn="$1"
  ck "$dn: exit 64, nothing started, no launch row" '[ "$(cat $T/rc.$dn)" = 64 ] && flr_spy_empty $dn && [ "$(flr_count $dn launch)" = 0 ]'
  ck "$dn: denied row \"resume role/scope differs\"" '[ "$(flr_count $dn denied)" = 1 ] && flr_get $dn .reasons | grep -qF "resume role/scope differs"'
}
flr_run ra1 rh --resume "$SA" -p x; differs ra1
ck "ra1: denied row carries the request's role review and S, session SA" '[ "$(flr_get ra1 "[.role,.scope_id,.session]|join(\",\")")" = "review,$S,$SA" ]'
flr_run ra2 rh --resume "$SA" --session-id "$SA" -p x; differs ra2
flr_run rr1 au --resume "$SR" -p x; differs rr1
flr_run rr2 au --resume "$SR" --session-id "$SR" -p x; differs rr2
flr_req rs A5 "$FX/single.sha256"; flr_run rs1 rs --resume "$SR" -p x; differs rs1
flr_run rs2 rs --resume "$SR" --session-id "$SR" -p x; differs rs2
flr_req ot A5-OTHER; flr_run ro1 ot --resume "$SR" -p x; differs ro1
flr_req ots A5-OTHER "$FX/single.sha256"; flr_run ro2 ots --resume "$SR" -p x; differs ro2
# AC 5 as amended by A1300 FFDR spec r2 (§ Amendments, F6): SR ended clean (its outcome is completed), so resuming it would review the same
# bytes again: unchanged-review-replay, nothing started. A resume after a non-clean end stays a continuation with its recorded role and scope.
flr_req rp A5 "$FX/prefixed.sha256"; flr_run rok rp --resume "$SR" -p again
ck "completed reviewer resumed with its own scope (other prefix): 64, nothing started, one denied row unchanged-review-replay (amended AC 5)" '[ "$FLR_RC" = 64 ] && flr_spy_empty rok && [ "$(flr_count rok launch)" = 0 ] && [ "$(flr_count rok denied)" = 1 ] && flr_get rok .reasons | grep -qF "unchanged-review-replay: review session $SR already completed"'
flr_run rok2 rp --resume "$SR" --session-id "$SR" -p again
ck "the same resume beside --session-id (still a resume): refused the same way" '[ "$FLR_RC" = 64 ] && flr_spy_empty rok2 && [ "$(flr_get rok2 "[.decision,.role,.scope_id]|join(\",\")")" = "denied,review,$S" ] && flr_get rok2 .reasons | grep -qF "unchanged-review-replay"'
SF="$(uuid)"; flr_req rf A5-F "$FX/happy.sha256"; FLR_SPY_RC=1 flr_run rf rf --session-id "$SF" -p x
flr_req rfp A5-F "$FX/prefixed.sha256"; FABLE_LAUNCH_ACK_UNKNOWN_EFFECT=1 FLR_SPY_RC=1 flr_run rfok rfp --resume "$SF" -p again
ck "reviewer that ended non-clean, resumed (with the ack) with its own scope (other prefix): proceeds as review S" '[ "$FLR_RC" = 1 ] && grep -q -- "--resume $SF" "$T/spy.rfok" && [ "$(flr_get rfok "[.decision,.role,.scope_id]|join(\",\")")" = "launch,review,$S" ]'
FABLE_LAUNCH_ACK_UNKNOWN_EFFECT=1 flr_run rfok2 rfp --resume "$SF" --session-id "$SF" -p again
ck "that reviewer resumed beside --session-id with its own scope proceeds (model/effort rule as today: resume false)" '[ "$FLR_RC" = 0 ] && [ "$(flr_get rfok2 "[.decision,.role,(.resume|tostring)]|join(\",\")")" = "launch,review,false" ]'
# A session whose latest launch row has no role, or an unrecognized one, is an author. The injected row repeats the session's own route,
# model, effort and account (the same-session resume route rule reads them), so only the role differs.
for v in none bogus; do
  flr_req "l$v" A5; flr_run "l$v" "l$v" -p x; s="$(flr_get l$v .session)"
  case $v in none) r='{}';; bogus) r='{"role":"Review","scope_id":""}';; esac
  flr_inject "$(flr_get "l$v" 'select(.decision=="launch") | tojson' | jq -c --arg s "$s" --argjson r "$r" '{ts:"2026-11-02T00:00:00-08:00",decision:"launch",task_id:"A5",skill:"dream",route,model,effort,account,session:$s,resume:false,reasons:"fixture"} + $r')"
  flr_run "lr$v" rh --resume "$s" -p x; differs "lr$v"
  flr_run "la$v" "l$v" --resume "$s" -p x
  ck "latest row role $v, no snapshot: runs as an author" '[ "$FLR_RC" = 0 ] && grep -q -- "--resume $s" "$T/spy.la$v" && [ "$(flr_get la$v .role)" = author ]'
done
# A resume of a session with no launch row compares against nothing; the lane claim's session_unmapped (75) refuses it and nothing starts.
NS="$(uuid)"; flr_run un rh --resume "$NS" -p x
ck "review resume of a session with no launch row: 75, no launch row, nothing started" '[ "$FLR_RC" = 75 ] && flr_spy_empty un && [ "$(flr_count un launch)" = 0 ]'
flr_end
