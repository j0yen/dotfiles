#!/usr/bin/env bash
# analysis-route AC 4 (A1300 E13 R2): a policy copy whose alternates is malformed in any R2 way denies every request for that skill
# with exit 2 and an error naming alternates (checked right after the skill lookup, before require_permission_mode: F36), and every
# other skill still resolves. Copies are made from the policy under test with jq. From R (AR_ROOT): policy and resolver.
# Run alone: bash tests/analysis-route_ac04_alternates_malformed.test.sh
. "$(dirname "$0")/analysis-route_lib.sh"
POL="$R/.config/skill-routing/policy.json"; RES="$R/.local/lib/skill-route-resolve.py"
EVR=',"evidence_refs":'"$EVJ"
OPX='{"route":"opus-xhigh","model":"claude-opus-5-5","effort":"xhigh"}'; OPH='{"route":"opus-high","model":"claude-opus-5-5","effort":"high"}'
REV=',"review":{"reason":"contradiction","evidence":'"$EVJ"'}'
# the requests each skill is asked under a malformed copy (every shape: baseline, class, escalation, alternate, route-only, review, mode),
# each prefixed with its exit code under the well-formed policy (the control below)
reqs_for(){ case "$1" in
  wwhtbt) printf '%s\n' '0 {"task_id":"AR4","skill":"wwhtbt"}' \
    '0 {"task_id":"AR4","skill":"wwhtbt","decision_class":"straightforward_reversible"}' \
    '0 {"task_id":"AR4","skill":"wwhtbt","decision_class":"unresolved_consequential"'"$EVR"'}' \
    '0 {"task_id":"AR4","skill":"wwhtbt","decision_class":"unresolved_consequential"'"$EVR"',"requested":'"$OPX"'}' \
    '2 {"task_id":"AR4","skill":"wwhtbt","escalation":{"reason":"strategy_cross_system","evidence":'"$EVJ"'},"requested":{"route":"opus-high"}}' \
    '0 {"task_id":"AR4","skill":"wwhtbt","decision_class":"strategy_cross_system"'"$EVR$REV"'}' ;;
  5whysandrhyme) printf '%s\n' '0 {"task_id":"AR4","skill":"5whysandrhyme"}' \
    '0 {"task_id":"AR4","skill":"5whysandrhyme","requested":'"$OPH"'}' \
    '0 {"task_id":"AR4","skill":"5whysandrhyme","decision_class":"consequential_prevention"'"$EVR$REV"'}' ;;
  dream) printf '%s\n' '0 {"task_id":"AR4","skill":"dream","decision_class":"amendment"}' \
    '0 {"task_id":"AR4","skill":"dream","decision_class":"discovery"}' \
    '0 {"task_id":"AR4","skill":"dream","decision_class":"new_vision"'"$EVR"'}' ;;
  maxspeed) printf '%s\n' '0 {"task_id":"AR4","skill":"maxspeed","permission_mode":"plan"}' \
    '2 {"task_id":"AR4","skill":"maxspeed"}' \
    '2 {"task_id":"AR4","skill":"maxspeed","permission_mode":"default"}' ;;
esac; }
# every other skill still resolves: one baseline-shaped request each, plus the other analysis skill's alternate
others(){ printf '%s\n' '{"task_id":"AR4","skill":"5whysandrhyme"}' '{"task_id":"AR4","skill":"wwhtbt"}' \
  '{"task_id":"AR4","skill":"dream","decision_class":"amendment"}' '{"task_id":"AR4","skill":"maxspeed","permission_mode":"plan"}' \
  '{"task_id":"AR4","skill":"5whysandrhyme","requested":'"$OPH"'}' \
  '{"task_id":"AR4","skill":"wwhtbt","decision_class":"unresolved_consequential"'"$EVR"',"requested":'"$OPX"'}' | grep -v "\"skill\":\"$1\""; }

ck "control: under the policy under test (well-formed alternates) every request used below exits as listed (0, or 2 for a route-only request and a maxspeed request without permission_mode plan)" '
  bad=0; for s in wwhtbt 5whysandrhyme dream maxspeed; do while read -r want q; do ar_res "$POL" "$RES" "$q"
    [ "$AR_RC" = "$want" ] || { bad=1; echo "  control $q: rc=$AR_RC want $want"; }; done < <(reqs_for $s); done; [ $bad = 0 ]'

# case label | skill | jq edit of the policy under test (one R2 way each)
CASES='not-an-object (array)|wwhtbt|.skills.wwhtbt.alternates=[]
not-an-object (string)|wwhtbt|.skills.wwhtbt.alternates="opus-high"
not-an-object (null)|wwhtbt|.skills.wwhtbt.alternates=null
key not a route of the skill|wwhtbt|.skills.wwhtbt.alternates={"fable-highest":["opus-high"]}
key a deterministic route|dream|.skills.dream.alternates={"deterministic":["opus-high"]}
key an exception route|dream|.skills.dream.alternates={"fable-max-exception":["opus-xhigh"]}
key a route whose family is not fable (sonnet-medium, F23)|wwhtbt|.skills.wwhtbt.alternates={"sonnet-medium":["opus-high"]}
key a route whose family is not fable (opus-high)|wwhtbt|.skills.wwhtbt.alternates={"opus-high":["opus-xhigh"]}
value an empty list|wwhtbt|.skills.wwhtbt.alternates={"fable-high":[]}
value not a list|wwhtbt|.skills.wwhtbt.alternates={"fable-high":"opus-high"}
value with a repeated name|wwhtbt|.skills.wwhtbt.alternates={"fable-high":["opus-high","opus-high"]}
value with a non-string member|wwhtbt|.skills.wwhtbt.alternates={"fable-high":[7]}
member not a route of the skill|wwhtbt|.skills.wwhtbt.alternates={"fable-high":["opus-highest"]}
member a deterministic route|dream|.skills.dream.alternates={"fable-high":["deterministic"]}
member an exception route|wwhtbt|.skills.wwhtbt.routes["opus-exc"]={"model":"claude-opus-5-5","effort":"high","exception":true} | .skills.wwhtbt.alternates={"fable-high":["opus-exc"]}
member whose model entry has no family|wwhtbt|.models["claude-x-1"]={"efforts":["high"]} | .skills.wwhtbt.routes["x-high"]={"model":"claude-x-1","effort":"high"} | .skills.wwhtbt.alternates={"fable-high":["x-high"]}
member whose family is not a string|wwhtbt|.models["claude-x-1"]={"efforts":["high"],"family":7} | .skills.wwhtbt.routes["x-high"]={"model":"claude-x-1","effort":"high"} | .skills.wwhtbt.alternates={"fable-high":["x-high"]}
member whose model has no policy entry|wwhtbt|.skills.wwhtbt.routes["x-high"]={"model":"claude-x-9","effort":"high"} | .skills.wwhtbt.alternates={"fable-high":["x-high"]}
member whose family is fable|wwhtbt|.skills.wwhtbt.routes["fable-high-2"]={"model":"claude-fable-5-1","effort":"high"} | .skills.wwhtbt.alternates={"fable-high":["fable-high-2"]}
member whose model id contains fable (any case) under another family|wwhtbt|.models["claude-FABLE-5-2"]={"efforts":["high"],"family":"opus"} | .skills.wwhtbt.routes["fx-high"]={"model":"claude-FABLE-5-2","effort":"high"} | .skills.wwhtbt.alternates={"fable-high":["fx-high"]}
member whose effort is forbidden|wwhtbt|.models["claude-opus-5-5"].efforts+=["max"] | .skills.wwhtbt.routes["fable-max"]={"model":"claude-fable-5-1","effort":"max"} | .skills.wwhtbt.routes["opus-max"]={"model":"claude-opus-5-5","effort":"max"} | .skills.wwhtbt.alternates={"fable-max":["opus-max"]}
member whose effort is unsupported for its model|wwhtbt|.skills.wwhtbt.routes["fable-medium"]={"model":"claude-fable-5-1","effort":"medium"} | .skills.wwhtbt.routes["opus-medium"]={"model":"claude-opus-5-5","effort":"medium"} | .skills.wwhtbt.alternates={"fable-medium":["opus-medium"]}
member whose effort differs from its key (fable-high -> opus-xhigh, F23)|wwhtbt|.skills.wwhtbt.alternates={"fable-high":["opus-xhigh"]}
member whose effort differs from its key (5whysandrhyme)|5whysandrhyme|.skills["5whysandrhyme"].alternates={"fable-xhigh":["opus-high"]}
member equal to its key|wwhtbt|.skills.wwhtbt.alternates={"fable-high":["fable-high"]}
maxspeed copy with malformed alternates, with and without permission_mode (F36)|maxspeed|.skills.maxspeed.alternates={"fable-high":["opus-high"]}'
n=0
while IFS='|' read -r label skill edit; do
  n=$((n+1)); cp_="$T/pol.$n.json"
  jq "$edit" "$POL" >"$cp_" 2>"$T/jq.err" || { ck "$label: policy copy built" false; continue; }
  den=0; tot=0; named=0
  while read -r _ q; do tot=$((tot+1)); ar_res "$cp_" "$RES" "$q"
    [ "$AR_RC" = 2 ] && den=$((den+1)); jq -e '.error|test("policy alternates")' "$T/res.out" >/dev/null 2>&1 && named=$((named+1)); done < <(reqs_for "$skill")
  ck "$label: all $tot requests for $skill exit 2 naming alternates" '[ "$tot" -gt 0 ] && [ "$den" = "$tot" ] && [ "$named" = "$tot" ]' || echo "  last: $(head -c 300 "$T/res.out")"
  oth=0; okn=0
  while IFS= read -r q; do oth=$((oth+1)); ar_res "$cp_" "$RES" "$q"; [ "$AR_RC" = 0 ] && okn=$((okn+1)); done < <(others "$skill")
  ck "$label: every other skill still resolves ($oth requests)" '[ "$oth" -gt 0 ] && [ "$okn" = "$oth" ]'
done <<<"$CASES"
ck "every R2 way was exercised (26 copies)" '[ "$n" = 26 ]'
ar_end
