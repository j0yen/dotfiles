#!/usr/bin/env bash
# skill-no-default-second-review.test.sh: 5whysandrhyme/wwhtbt launch Fable once by default; a second
# review needs a recorded justified reason (ledger A1300). No provider calls.
# Run alone: bash tests/skill-no-default-second-review.test.sh
set -u
R="$(cd "$(dirname "$0")/.." && pwd)"
RES="$R/.local/lib/skill-route-resolve.py"
export SKILL_ROUTE_POLICY="$R/.config/skill-routing/policy.json"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export SKILL_ROUTE_LEDGER_IDS="$T/ids.txt"; printf 'A1300\n' >"$SKILL_ROUTE_LEDGER_IDS"
echo evidence >"$T/ev.md"; EV='["ledger:A1300","file:'"$T"'/ev.md"]'
fail=0
ok(){ echo "PASS $1"; }; no(){ echo "FAIL $1"; fail=1; }
for sk in 5whysandrhyme wwhtbt; do
  f="$R/.claude/skills/$sk/SKILL.md"
  [ -f "$f" ] || { no "$sk SKILL.md in repo"; continue; }
  # default path: the only unconditional fable-launch step is the synthesis; review step is conditional
  grep -q "No second Fable launch\|default: no second Fable launch" "$f" && ok "$sk states default no second launch" || no "$sk states default no second launch"
  grep -q "One Fable review turn" "$f" && no "$sk no unconditional 'One Fable review turn' step" || ok "$sk no unconditional review step"
  grep -qi "sends it to one Fable review turn" "$f" && no "$sk description not forcing review" || ok "$sk description not forcing review"
  grep -q "review_reason:" "$f" && grep -q "explicit_user_request" "$f" && ok "$sk justified-review reasons recorded first" || no "$sk justified-review reasons recorded first"
  # launches in the step list: synthesis launch line precedes; review launch sits inside the conditional step only
  n=$(awk '/Review only when justified/{c=1} c&&/fable-launch\.sh/{k++} END{print k+0}' "$f")
  [ "$n" = 1 ] && ok "$sk exactly one fable-launch inside the conditional review step" || no "$sk review launch count=$n"
done
# resolver: default request has no review; second review only with justified reason + evidence
out=$(printf '%s' '{"task_id":"A1300","skill":"5whysandrhyme"}' | python3 -I "$RES" 2>/dev/null)
printf '%s' "$out" | jq -e 'has("review")|not' >/dev/null && ok "default resolve carries no review launch" || no "default resolve carries no review launch"
printf '%s' '{"task_id":"A1300","skill":"wwhtbt","review":{"reason":"automatic","evidence":'"$EV"'}}' | python3 -I "$RES" >/dev/null 2>&1; [ $? = 2 ] && ok "unjustified review denied" || no "unjustified review denied"
for rs in prod_money_real_user_data low_confidence_weakest_link explicit_user_request; do
  printf '%s' '{"task_id":"A1300","skill":"wwhtbt","review":{"reason":"'$rs'","evidence":'"$EV"'}}' | python3 -I "$RES" 2>/dev/null | jq -e '.review.model_id=="claude-fable-5-1"' >/dev/null && ok "justified flag $rs allows second" || no "justified flag $rs allows second"
done
exit $fail
