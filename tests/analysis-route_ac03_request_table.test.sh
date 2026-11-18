#!/usr/bin/env bash
# analysis-route AC 3 (A1300 E13 R1): every row of the PRD's request table Q1-Q18 gives its exit code, route, model, effort,
# alternate_of and reason or error text on the resolver and policy under test (private ledger-id file), and rows Q1-Q4 exit 2 on the
# vendored f9066716 resolver and policy (Q12 and Q18 exit 0 there). From R (AR_ROOT): policy and resolver.
# Run alone: bash tests/analysis-route_ac03_request_table.test.sh
. "$(dirname "$0")/analysis-route_lib.sh"
POL="$R/.config/skill-routing/policy.json"; RES="$R/.local/lib/skill-route-resolve.py"
ck "vendored f9066716 resolver and policy present with their full sha256 digests (missing or changed = FAIL)" 'ar_fixtures_ok'
rq(){ jq -cn --arg r "$1" --arg m "$2" --arg e "$3" '{} + (if $r != "-" then {route:$r} else {} end) + (if $m != "-" then {model:$m} else {} end) + (if $e != "-" then {effort:$e} else {} end)'; }
W='{"task_id":"AR-Q","skill":"wwhtbt"'; F='{"task_id":"AR-Q","skill":"5whysandrhyme"'
WUC="$W"',"decision_class":"unresolved_consequential","evidence_refs":'"$EVJ"
ALT='.alternate_of'
reason(){ printf '(.reasons | any(. == "requested alternate %s for %s"))' "$1" "$2"; }
MISMATCH='requested claude-opus-5-5/xhigh does not match the resolved route claude-fable-5-1/xhigh'

Q1="$WUC"',"requested":'"$(rq opus-xhigh $OPUS xhigh)"'}'
ar_q "Q1 wwhtbt unresolved_consequential +ev; route opus-xhigh, Opus, xhigh -> 0, opus-xhigh, Opus xhigh, alternate_of fable-xhigh, the reason" 0 "$Q1" \
  ".route==\"opus-xhigh\" and .model_id==\"$OPUS\" and .effort==\"xhigh\" and $ALT==\"fable-xhigh\" and $(reason opus-xhigh fable-xhigh)"
Q2="$F"',"requested":'"$(rq opus-high $OPUS high)"'}'
ar_q "Q2 5whysandrhyme, no class; route opus-high, Opus, high -> 0, opus-high, alternate_of fable-high" 0 "$Q2" \
  ".route==\"opus-high\" and .model_id==\"$OPUS\" and .effort==\"high\" and $ALT==\"fable-high\" and $(reason opus-high fable-high)"
Q3="$F"',"escalation":{"reason":"recurring_failure","evidence":'"$EVJ"'},"requested":'"$(rq opus-xhigh $OPUS xhigh)"'}'
ar_q "Q3 5whysandrhyme escalation recurring_failure +ev; route opus-xhigh, Opus, xhigh -> 0, opus-xhigh, alternate_of fable-xhigh" 0 "$Q3" \
  ".route==\"opus-xhigh\" and .model_id==\"$OPUS\" and .effort==\"xhigh\" and $ALT==\"fable-xhigh\" and $(reason opus-xhigh fable-xhigh)"

# Q4: every wwhtbt / 5whysandrhyme baseline, class and escalation request of the f9066716 table whose route R is fable-high or
# fable-xhigh, asking R's listed alternate (R3: opus-<effort>) with its model and effort. Rows come from the base fixture, not the policy.
jq -c '.table[] | select((.id|test("^(wwhtbt|5whysandrhyme)\\|(baseline|class:|escalation:)")) and .rc==0 and (.out.route|test("^fable-(high|xhigh)$")))
  | {id, r:.out.route, e:.out.effort, req:(.request + {requested:{route:("opus-" + .out.effort), model:"claude-opus-5-5", effort:.out.effort}})}' \
  "$AF/base-route-table.json" >"$T/q4.jsonl" 2>/dev/null
n4=0; ok4=0; base2=0; okmsg=0
while IFS= read -r row; do
  n4=$((n4+1)); rr=$(jq -r .r <<<"$row"); ee=$(jq -r .e <<<"$row"); rj=$(jq -c .req <<<"$row")
  ar_res "$POL" "$RES" "$rj"
  [ "$AR_RC" = 0 ] && jq -e --arg a "opus-$ee" --arg r "$rr" --arg e "$ee" --arg m "$OPUS" \
    '.route==$a and .model_id==$m and .effort==$e and .alternate_of==$r and (.reasons|any(. == "requested alternate \($a) for \($r)"))' "$T/res.out" >/dev/null 2>&1 \
    && ok4=$((ok4+1)) || echo "  Q4 row $(jq -r .id <<<"$row"): rc=$AR_RC $(head -c 300 "$T/res.out")"
  ar_res "$BPOL" "$BRES" "$rj"
  [ "$AR_RC" = 2 ] && base2=$((base2+1)); jq -e '.error|test("does not match the resolved route")' "$T/res.out" >/dev/null 2>&1 && okmsg=$((okmsg+1))
done <"$T/q4.jsonl"
ck "Q4 every other Fable-routed wwhtbt/5whysandrhyme baseline, class or escalation asking its listed alternate resolves to it (14 rows from the f9066716 table, Q1-Q3 included)" '[ "$n4" = 14 ] && [ "$ok4" = 14 ]'
ck "Q1-Q4 exit 2 on the vendored f9066716 resolver and policy, on its model-mismatch text (all 14 rows)" 'ar_fixtures_ok && [ "$base2" = 14 ] && [ "$okmsg" = 14 ]'

ar_q "Q5 Q1 with route only, no model or effort -> 2, naming requested.model" 2 "$WUC"',"requested":'"$(rq opus-xhigh - -)"'}' '.error|test("requested\\.model")'
ar_q "Q6 Q1 with model and effort but no route -> 2, today's mismatch text" 2 "$WUC"',"requested":'"$(rq - $OPUS xhigh)"'}' ".error==\"$MISMATCH\""
ar_q "Q7 Q1 with route opus-xhigh but effort high -> 2 (naming requested.effort)" 2 "$WUC"',"requested":'"$(rq opus-xhigh $OPUS high)"'}' '.error|test("requested\\.effort")'
ar_q "Q8 wwhtbt strategy_cross_system +ev (R fable-high); route opus-xhigh, Opus, xhigh -> 2, naming the route, R and alternates[R]" 2 \
  "$W"',"decision_class":"strategy_cross_system","evidence_refs":'"$EVJ"',"requested":'"$(rq opus-xhigh $OPUS xhigh)"'}' \
  '(.error|test("opus-xhigh")) and (.error|test("fable-high")) and (.error|test("alternates\\[fable-high\\]: opus-high"))'
ar_q "Q9 wwhtbt straightforward_reversible (R sonnet-medium); route opus-high, Opus, high -> 2, alternates none" 2 \
  "$W"',"decision_class":"straightforward_reversible","requested":'"$(rq opus-high $OPUS high)"'}' '(.error|test("opus-high")) and (.error|test("sonnet-medium")) and (.error|test("none"))'
ar_q "Q10 wwhtbt, no class (R sonnet-medium); route opus-high, Opus, high -> 2" 2 "$W"',"requested":'"$(rq opus-high $OPUS high)"'}' '(.error|test("sonnet-medium")) and (.error|test("none"))'
ar_q "Q11 wwhtbt unresolved_consequential +ev; route fable-xhigh (= R), Fable, xhigh -> 0, fable-xhigh, no alternate_of" 0 \
  "$WUC"',"requested":'"$(rq fable-xhigh $FABLE xhigh)"'}' ".route==\"fable-xhigh\" and .model_id==\"$FABLE\" and .effort==\"xhigh\" and (has(\"alternate_of\")|not) and (.reasons|any(test(\"requested alternate\"))|not)"
Q12='{"task_id":"AR-Q","skill":"dream","decision_class":"amendment","requested":{"route":"bogus"}}'
ar_q "Q12 dream amendment (R sonnet-medium); route bogus -> 2, naming the route" 2 "$Q12" '(.error|test("bogus")) and (.error|test("sonnet-medium"))'
ar_q "Q12 at f9066716 -> 0 (the deliberate tightening)" 0 "$Q12" '.route=="sonnet-medium"' "$BPOL" "$BRES"
ar_q "Q13 wwhtbt, no class; route 7 (not a string) -> 2" 2 "$W"',"requested":{"route":7}}' '.error|test("requested\\.route")'

# Q14: every request of the AC 2 table (none carries requested.route) resolves as at f9066716: same exit code and output.
jq -c '.table[]' "$AF/base-route-table.json" >"$T/q14.jsonl" 2>/dev/null; n14=0; ok14=0
while IFS= read -r row; do
  n14=$((n14+1)); ar_res "$POL" "$RES" "$(jq -c .request <<<"$row")"
  [ "$AR_RC" = "$(jq -r .rc <<<"$row")" ] && [ "$(jq -S -c . "$T/res.out" 2>/dev/null)" = "$(jq -S -c .out <<<"$row")" ] && ok14=$((ok14+1)) || echo "  Q14 $(jq -r .id <<<"$row") differs"
done <"$T/q14.jsonl"
ck "Q14 every request of the AC 2 table (61, no requested.route) resolves exactly as at f9066716" '[ "$n14" = 61 ] && [ "$ok14" = 61 ]'

ar_q "Q15 Q1 with model claude-fable-5-1 -> 2, naming requested.model" 2 "$WUC"',"requested":'"$(rq opus-xhigh $FABLE xhigh)"'}' '.error|test("requested\\.model claude-fable-5-1")'
ar_q "Q16 Q1 with route and model but no effort -> 2, naming requested.effort" 2 "$WUC"',"requested":'"$(rq opus-xhigh $OPUS -)"'}' '.error|test("requested\\.effort")'
ar_q "Q17 Q1 with route fable-xhigh (= R) but Opus xhigh -> 2, today's mismatch text" 2 "$WUC"',"requested":'"$(rq fable-xhigh $OPUS xhigh)"'}' ".error==\"$MISMATCH\""
Q18="$WUC"',"requested":{"route":null}}'
ar_q "Q18 wwhtbt unresolved_consequential +ev; route null, no model or effort -> 2, naming the route" 2 "$Q18" '.error|test("requested\\.route")'
ar_q "Q18 at f9066716 -> 0 (the deliberate tightening)" 0 "$Q18" '.route=="fable-xhigh"' "$BPOL" "$BRES"
# Placement (Technical considerations): an unknown model or forbidden effort in requested is refused before alternates are read.
ar_q "control: route opus-xhigh with an unknown model -> 2 unknown model" 2 "$WUC"',"requested":'"$(rq opus-xhigh claude-opus-4 xhigh)"'}' '.error|test("unknown model")'
ar_q "control: route opus-xhigh with effort max -> 2 forbidden effort" 2 "$WUC"',"requested":'"$(rq opus-xhigh $OPUS max)"'}' '.error|test("forbidden effort")'
ar_q "control: an alternate never escapes its key: 5whysandrhyme baseline (fable-high) asking opus-xhigh -> 2" 2 "$F"',"requested":'"$(rq opus-xhigh $OPUS xhigh)"'}' '.error|test("alternates\\[fable-high\\]: opus-high")'
ar_end
