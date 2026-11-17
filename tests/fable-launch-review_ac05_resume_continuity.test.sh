#!/usr/bin/env bash
# fable-launch-review AC 5: a resume keeps the session's recorded role and scope_id (R6), alone and beside --session-id, under its task or another.
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
flr_req rp A5 "$FX/prefixed.sha256"; flr_run rok rp --resume "$SR" -p again
ck "reviewer resumed with its own scope (other prefix) proceeds as review S" '[ "$FLR_RC" = 0 ] && grep -q -- "--resume $SR" "$T/spy.rok" && [ "$(flr_get rok "[.decision,.role,.scope_id]|join(\",\")")" = "launch,review,$S" ]'
flr_run rok2 rp --resume "$SR" --session-id "$SR" -p again
ck "reviewer resumed beside --session-id with its own scope proceeds (model/effort rule as today: resume false)" '[ "$FLR_RC" = 0 ] && [ "$(flr_get rok2 "[.decision,.role,(.resume|tostring)]|join(\",\")")" = "launch,review,false" ]'
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
