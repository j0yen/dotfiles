#!/usr/bin/env bash
# analysis-route AC 5 (A1300 E13 R4, disposition F37): a request that selects an alternate and carries review echoes the skill's
# review_route if it declares one, else the selected alternate's model and effort; a Fable review_route denies an alternate request,
# naming review_route; a request that selects no alternate gets today's echo (equal to the f9066716 output where f9066716 can resolve it).
# From R (AR_ROOT): policy and resolver. Run alone: bash tests/analysis-route_ac05_review_echo.test.sh
. "$(dirname "$0")/analysis-route_lib.sh"
POL="$R/.config/skill-routing/policy.json"; RES="$R/.local/lib/skill-route-resolve.py"
ck "vendored f9066716 resolver and policy present with their full sha256 digests (missing or changed = FAIL)" 'ar_fixtures_ok'
REV=',"review":{"reason":"contradiction","evidence":'"$EVJ"'}'
WUC='{"task_id":"AR5","skill":"wwhtbt","decision_class":"unresolved_consequential","evidence_refs":'"$EVJ"
OPX=',"requested":{"route":"opus-xhigh","model":"claude-opus-5-5","effort":"xhigh"}'
OPH=',"requested":{"route":"opus-high","model":"claude-opus-5-5","effort":"high"}'
echo_is(){ printf '.review=={"model_id":"%s","effort":"%s","reason":"contradiction"}' "$1" "$2"; }

# alternate selected, no review_route declared (the policy as shipped): the alternate's own model and effort
ar_q "wwhtbt opus-xhigh alternate + review, no review_route -> echo claude-opus-5-5 xhigh (the alternate's)" 0 "$WUC$OPX$REV}" "$(echo_is $OPUS xhigh) and .alternate_of==\"fable-xhigh\""
ar_q "5whysandrhyme opus-high alternate (no class) + review -> echo claude-opus-5-5 high" 0 '{"task_id":"AR5","skill":"5whysandrhyme"'"$OPH$REV}" "$(echo_is $OPUS high)"
ar_q "5whysandrhyme escalated opus-xhigh alternate + review -> echo claude-opus-5-5 xhigh" 0 '{"task_id":"AR5","skill":"5whysandrhyme","escalation":{"reason":"recurring_failure","evidence":'"$EVJ"'}'"$OPX$REV}" "$(echo_is $OPUS xhigh)"
SN=',"snapshot":"/s/m.sha256","replay":{"reason":"prior reviewer died mid-run","evidence":["ledger:A1300"],"prior":["11111111-2222-4333-8444-555555555555"]}'
ar_q "alternate + review with snapshot and replay -> the alternate's echo keeps the validated replay" 0 "$WUC$OPX"',"review":{"reason":"contradiction","evidence":'"$EVJ$SN"'}}' \
  ".review.model_id==\"$OPUS\" and .review.effort==\"xhigh\" and .review.replay.prior==[\"11111111-2222-4333-8444-555555555555\"]"

# a declared review_route: echoed when non-Fable (opus-high), denied when Fable (F37), with and without review
jq '.skills.wwhtbt.review_route="opus-high"' "$POL" >"$T/rr-opus.json"; jq '.skills.wwhtbt.review_route="fable-high"' "$POL" >"$T/rr-fable.json"
jq '.skills["5whysandrhyme"].review_route="fable-xhigh"' "$POL" >"$T/rr-5w-fable.json"
ar_q "copy: wwhtbt review_route opus-high; opus-xhigh alternate + review -> echo the review_route, claude-opus-5-5 high (not the alternate's xhigh)" 0 "$WUC$OPX$REV}" "$(echo_is $OPUS high)" "$T/rr-opus.json"
ar_q "copy: wwhtbt review_route fable-high; opus-xhigh alternate + review -> 2 naming review_route" 2 "$WUC$OPX$REV}" '.error|test("review_route")' "$T/rr-fable.json"
ar_q "copy: wwhtbt review_route fable-high; opus-xhigh alternate without review -> 2 naming review_route (F37)" 2 "$WUC$OPX}" '.error|test("review_route")' "$T/rr-fable.json"
ar_q "copy: 5whysandrhyme review_route fable-xhigh; opus-high alternate + review -> 2 naming review_route" 2 '{"task_id":"AR5","skill":"5whysandrhyme"'"$OPH$REV}" '.error|test("review_route")' "$T/rr-5w-fable.json"

# no alternate selected: today's echo
ar_q "copy: wwhtbt review_route opus-high; default Fable route + review (no alternate) -> echo the review_route as today" 0 "$WUC$REV}" "$(echo_is $OPUS high) and (has(\"alternate_of\")|not)" "$T/rr-opus.json"
ar_q "copy: wwhtbt review_route fable-high; default route + review (no alternate) -> 0, echo claude-fable-5-1 high as today" 0 "$WUC$REV}" "$(echo_is $FABLE high)" "$T/rr-fable.json"
same_as_base(){ local a b; ar_res "$POL" "$RES" "$1"; a="$AR_RC $(jq -S -c . "$T/res.out" 2>/dev/null)"; ar_res "$BPOL" "$BRES" "$1"; b="$AR_RC $(jq -S -c . "$T/res.out" 2>/dev/null)"
  [ "$a" = "$b" ] && [ "${a%% *}" = 0 ] && jq -e '.review.model_id' "$T/res.out" >/dev/null 2>&1; }
ck "no alternate: wwhtbt unresolved_consequential + review gives the f9066716 output (global echo claude-fable-5-1 high)" 'same_as_base "$WUC$REV}"'
ck "no alternate: requested.route equal to R (fable-xhigh) + review gives the f9066716 output (route = R selects nothing)" 'same_as_base "$WUC"",\"requested\":{\"route\":\"fable-xhigh\",\"model\":\"claude-fable-5-1\",\"effort\":\"xhigh\"}$REV}"'
ck "no alternate: wwhtbt baseline sonnet-medium + review gives the f9066716 output" 'same_as_base "{\"task_id\":\"AR5\",\"skill\":\"wwhtbt\"$REV}"'
ck "no alternate: 5whysandrhyme baseline + review gives the f9066716 output" 'same_as_base "{\"task_id\":\"AR5\",\"skill\":\"5whysandrhyme\"$REV}"'
ck "no alternate: dream new_vision + review keeps its review_route echo (claude-opus-5-5 high), as at f9066716" 'same_as_base "{\"task_id\":\"AR5\",\"skill\":\"dream\",\"decision_class\":\"new_vision\",\"evidence_refs\":$EVJ$REV}"'
ar_end
