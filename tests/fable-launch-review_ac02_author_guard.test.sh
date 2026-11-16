#!/usr/bin/env bash
# fable-launch-review AC 2: a live author refuses a second author (73) and admits a reviewer; the author's resume is not refused for a live reviewer (R5).
# Run alone: bash tests/fable-launch-review_ac02_author_guard.test.sh
. "$(dirname "$0")/fable-launch-review_lib.sh"
flr_begin
flr_req au A2; flr_run a1 au -p x; SA="$(flr_get a1 .session)"
ck "author launches (role author)" '[ "$FLR_RC" = 0 ] && [ "$(flr_get a1 .role)" = author ]'
flr_live "$SA"; LA=$FLR_LIVE
flr_run a2 au -p x
ck "second author beside a live author: 73, nothing started" '[ "$FLR_RC" = 73 ] && flr_spy_empty a2'
ck "second author: one denied row naming the live session, no launch row" '[ "$(flr_count a2 denied)" = 1 ] && [ "$(flr_count a2 launch)" = 0 ] && flr_get a2 .reasons | grep -qF "$SA"'
SR="$(uuid)"; flr_req rv A2 "$FX/happy.sha256"; flr_run r1 rv --session-id "$SR" -p x
ck "review request beside the live author: exit 0 and a role review launch row" '[ "$FLR_RC" = 0 ] && [ "$(flr_get r1 "select(.decision==\"launch\") | .role")" = review ] && ! flr_spy_empty r1'
flr_kill "$LA"; flr_live "$SR"; LR=$FLR_LIVE
flr_run a3 au --resume "$SA" -p again
ck "author resume (author exited, reviewer live) is not refused: rc 0, spy resumed that session" '[ "$FLR_RC" = 0 ] && grep -q -- "--resume $SA" "$T/spy.a3"'
ck "author resume row: launch, role author, resume true" '[ "$(flr_get a3 "[.decision,.role,(.resume|tostring)] | join(\",\")")" = "launch,author,true" ]'
flr_req au2 A2 ; flr_run a4 au2 -p x
ck "a fresh author beside only a live reviewer proceeds" '[ "$FLR_RC" = 0 ]'
flr_kill "$LR"
# A latest launch row whose role is absent or unrecognized is an author.
for v in none bogus empty; do
  s="$(uuid)"; case $v in none) r='{}';; bogus) r='{"role":"reviewer"}';; empty) r='{"role":""}';; esac
  flr_inject "$(jq -nc --arg s "$s" --arg t "A2-$v" --argjson r "$r" '{ts:"2026-11-02T00:00:00-08:00",decision:"launch",task_id:$t,skill:"dream",route:"fable-xhigh",model:"claude-fable-5-1",effort:"xhigh",account:"jyen.pm",session:$s,resume:false,reasons:"fixture"} + $r')"
  flr_live "$s"; lv=$FLR_LIVE
  flr_req "x$v" "A2-$v"; flr_run "x$v" "x$v" -p x
  ck "live session with role $v is an author: second author 73, denied row names it" '[ "$FLR_RC" = 73 ] && flr_spy_empty x$v && flr_get x$v .reasons | grep -qF "$s"'
  flr_req "y$v" "A2-$v" "$FX/single.sha256"; flr_run "y$v" "y$v" --session-id "$(uuid)" -p x
  ck "live session with role $v does not block a reviewer" '[ "$FLR_RC" = 0 ] && [ "$(flr_get y$v .role)" = review ]'
  flr_kill "$lv"
done
flr_end
