#!/usr/bin/env bash
# skill-route-resolve.test.sh: adaptive skill routing resolver (ledger A1300). No provider calls.
# Run alone: bash tests/skill-route-resolve.test.sh
set -u
R="$(cd "$(dirname "$0")/.." && pwd)"
RES="$R/.local/lib/skill-route-resolve.py"
export SKILL_ROUTE_POLICY="$R/.config/skill-routing/policy.json"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export SKILL_ROUTE_LEDGER_IDS="$T/ids.txt"; printf 'A1300\n' >"$SKILL_ROUTE_LEDGER_IDS"
echo evidence >"$T/ev.md"
fail=0
# chk NAME WANT_RC JSON_LITERAL JQ_ASSERT   (assert evaluated against the output JSON; "" skips)
chk(){ local out rc; out=$(printf '%s' "$3" | python3 -I "$RES" 2>/dev/null); rc=$?
  if [ "$rc" != "$2" ]; then echo "FAIL $1 rc=$rc want $2: $out"; fail=1; return; fi
  if [ -n "${4:-}" ] && ! printf '%s' "$out" | jq -e "$4" >/dev/null 2>&1; then echo "FAIL $1 assert '$4' on: $out"; fail=1; return; fi
  echo "PASS $1"; }
EV='["ledger:A1300","file:'"$T"'/ev.md"]'
chk "5whys baseline (no class) = fable high" 0 '{"task_id":"A1300","skill":"5whysandrhyme"}' '.model_id=="claude-fable-5-1" and .effort=="high" and .route=="fable-high"'
chk "5whys explicit baseline class" 0 '{"task_id":"A1300","skill":"5whysandrhyme","decision_class":"baseline"}' '.effort=="high"'
chk "wwhtbt baseline (no class) = sonnet medium" 0 '{"task_id":"A1300","skill":"wwhtbt"}' '.model_id=="claude-sonnet-5-5" and .effort=="medium"'
chk "wwhtbt straightforward = sonnet medium" 0 '{"task_id":"A1300","skill":"wwhtbt","decision_class":"straightforward_reversible"}' '.route=="sonnet-medium"'
chk "wwhtbt strategy upfront (class+evidence) = fable high" 0 '{"task_id":"A1300","skill":"wwhtbt","decision_class":"strategy_cross_system","evidence_refs":'"$EV"'}' '.model_id=="claude-fable-5-1" and .effort=="high"'
chk "wwhtbt contested upfront = fable xhigh" 0 '{"task_id":"A1300","skill":"wwhtbt","decision_class":"contested_assumptions","evidence_refs":'"$EV"'}' '.effort=="xhigh"'
chk "wwhtbt strategy class without evidence denied" 2 '{"task_id":"A1300","skill":"wwhtbt","decision_class":"strategy_cross_system"}'
chk "5whys escalated recurring_failure = xhigh" 0 '{"task_id":"A1300","skill":"5whysandrhyme","escalation":{"reason":"recurring_failure","evidence":'"$EV"'}}' '.effort=="xhigh" and (.reasons|join(" ")|contains("recurring_failure"))'
chk "5whys escalated via class + escalation" 0 '{"task_id":"A1300","skill":"5whysandrhyme","decision_class":"contradictory_evidence","escalation":{"reason":"contradictory_evidence","evidence":'"$EV"'}}' '.effort=="xhigh"'
chk "wwhtbt escalated from baseline to fable xhigh" 0 '{"task_id":"A1300","skill":"wwhtbt","escalation":{"reason":"contested_assumptions","evidence":'"$EV"'}}' '.model_id=="claude-fable-5-1" and .effort=="xhigh"'
chk "escalation reason 'complex' denied" 2 '{"task_id":"A1300","skill":"5whysandrhyme","escalation":{"reason":"complex","evidence":'"$EV"'}}'
chk "escalation reason missing denied" 2 '{"task_id":"A1300","skill":"5whysandrhyme","escalation":{"evidence":'"$EV"'}}'
chk "escalation evidence missing denied" 2 '{"task_id":"A1300","skill":"5whysandrhyme","escalation":{"reason":"recurring_failure"}}'
chk "escalation evidence empty list denied" 2 '{"task_id":"A1300","skill":"5whysandrhyme","escalation":{"reason":"recurring_failure","evidence":[]}}'
chk "escalation evidence placeholder denied" 2 '{"task_id":"A1300","skill":"5whysandrhyme","escalation":{"reason":"recurring_failure","evidence":["file:none"]}}'
chk "escalation evidence free text denied" 2 '{"task_id":"A1300","skill":"5whysandrhyme","escalation":{"reason":"recurring_failure","evidence":["it was really complex"]}}'
chk "escalation evidence nonexistent file denied" 2 '{"task_id":"A1300","skill":"5whysandrhyme","escalation":{"reason":"recurring_failure","evidence":["file:'"$T"'/nope.md"]}}'
chk "escalation evidence unknown ledger id denied" 2 '{"task_id":"A1300","skill":"5whysandrhyme","escalation":{"reason":"recurring_failure","evidence":["ledger:A9999"]}}'
chk "escalation not an object denied" 2 '{"task_id":"A1300","skill":"5whysandrhyme","escalation":"yes"}'
chk "requested = resolved route allowed" 0 '{"task_id":"A1300","skill":"5whysandrhyme","requested":{"model":"claude-fable-5-1","effort":"high"}}'
chk "requested xhigh on baseline denied (mismatch)" 2 '{"task_id":"A1300","skill":"5whysandrhyme","requested":{"model":"claude-fable-5-1","effort":"xhigh"}}'
chk "requested unknown model denied" 2 '{"task_id":"A1300","skill":"wwhtbt","requested":{"model":"gpt-5-codex","effort":"medium"}}'
chk "requested unknown effort denied" 2 '{"task_id":"A1300","skill":"wwhtbt","requested":{"model":"claude-sonnet-5-5","effort":"turbo"}}'
chk "requested fable max denied" 2 '{"task_id":"A1300","skill":"5whysandrhyme","requested":{"model":"claude-fable-5-1","effort":"max"}}'
chk "requested alias 'fable' (not a pinned id) denied" 2 '{"task_id":"A1300","skill":"5whysandrhyme","requested":{"model":"fable","effort":"high"}}'
chk "unknown decision_class denied" 2 '{"task_id":"A1300","skill":"wwhtbt","decision_class":"strongest"}'
chk "governed skill without task_id denied" 2 '{"skill":"wwhtbt"}'
chk "malformed JSON denied" 2 '{"task_id":"A1300","skill":'
chk "empty input denied" 2 ''
chk "non-object JSON denied" 2 '[1,2]'
chk "second review without reason denied" 2 '{"task_id":"A1300","skill":"5whysandrhyme","review":{}}'
chk "second review 'automatic' denied" 2 '{"task_id":"A1300","skill":"5whysandrhyme","review":{"reason":"automatic","evidence":'"$EV"'}}'
chk "second review justified w/o evidence denied" 2 '{"task_id":"A1300","skill":"5whysandrhyme","review":{"reason":"contradiction"}}'
chk "second review justified with evidence allowed" 0 '{"task_id":"A1300","skill":"5whysandrhyme","review":{"reason":"independent_verifier_required","evidence":'"$EV"'}}' '.review.model_id=="claude-fable-5-1" and .review.effort=="high"'
chk "ungoverned skill (beauty) passes through" 0 '{"skill":"beauty"}' '.governed==false and .model_id==null'
chk "unrelated skill ungoverned (no task_id needed)" 0 '{"skill":"write"}' '.governed==false'
# injection/quoting: hostile strings are data. A marker file must never appear and results stay correct.
M="$T/pwned"
INJ='$(touch '"$M"')`touch '"$M"'`
; touch '"$M"' #'
J=$(jq -cn --arg i "$INJ" '{task_id:"A1300",skill:"wwhtbt",task_text:$i,decision_class:"straightforward_reversible"}')
chk "injection in extra field is inert" 0 "$J" '.route=="sonnet-medium"'
J=$(jq -cn --arg i "$INJ" '{task_id:"A1300",skill:"wwhtbt",decision_class:$i}')
chk "injection in decision_class denied" 2 "$J"
J=$(jq -cn --arg i "$INJ" '{task_id:$i,skill:"wwhtbt"}')
chk "injection in task_id denied" 2 "$J"
J=$(jq -cn --arg i "$INJ" '{task_id:"A1300",skill:"5whysandrhyme",escalation:{reason:"recurring_failure",evidence:[$i]}}')
chk "injection in evidence ref denied" 2 "$J"
[ ! -e "$M" ] && echo "PASS no injected command ran" || { echo "FAIL injected command ran"; fail=1; }
# argv file input
printf '{"task_id":"A1300","skill":"wwhtbt"}' >"$T/in.json"
python3 -I "$RES" --file "$T/in.json" | jq -e '.effort=="medium"' >/dev/null && echo "PASS --file input" || { echo "FAIL --file input"; fail=1; }
# malformed policy fails closed
echo '{' >"$T/bad.json"
printf '{"task_id":"A1300","skill":"wwhtbt"}' | python3 -I "$RES" --policy "$T/bad.json" >/dev/null 2>&1; [ $? = 2 ] && echo "PASS malformed policy denied" || { echo "FAIL malformed policy"; fail=1; }
[ "$fail" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
