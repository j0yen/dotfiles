#!/usr/bin/env bash
# dream-phase-routing.test.sh: /dream phase routing through the shared resolver (ledger A1301). No provider calls.
# Phases are decision_class values in policy.json; deterministic phases resolve to no model; /dream has no baseline.
# Run alone: bash tests/dream-phase-routing.test.sh
set -u
R="$(cd "$(dirname "$0")/.." && pwd)"
RES="$R/.local/lib/skill-route-resolve.py"
export SKILL_ROUTE_POLICY="$R/.config/skill-routing/policy.json"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export SKILL_ROUTE_LEDGER_IDS="$T/ids.txt"; printf 'A1301\nA1300\n' >"$SKILL_ROUTE_LEDGER_IDS"
echo evidence >"$T/ev.md"; EV='["ledger:A1301","file:'"$T"'/ev.md"]'
fail=0
chk(){ local out rc; out=$(printf '%s' "$3" | python3 -I "$RES" 2>/dev/null); rc=$?
  if [ "$rc" != "$2" ]; then echo "FAIL $1 rc=$rc want $2: $out"; fail=1; return; fi
  if [ -n "${4:-}" ] && ! printf '%s' "$out" | jq -e "$4" >/dev/null 2>&1; then echo "FAIL $1 assert '$4' on: $out"; fail=1; return; fi
  echo "PASS $1"; }
D='{"task_id":"A1301","skill":"dream"'
chk "dream governed by policy" 0 "$D"',"decision_class":"discovery"}' '.governed==true'
chk "no phase = denied (no inherited dream model)" 2 "$D"'}'
chk "unknown phase denied" 2 "$D"',"decision_class":"vibes"}'
for p in discovery contract duplicates lint manifest persistence; do
  chk "deterministic phase $p = no model" 0 "$D"',"decision_class":"'$p'"}' '.deterministic==true and .model_id==null and .effort==null'
done
for p in extraction inventory classification; do
  chk "phase $p = haiku" 0 "$D"',"decision_class":"'$p'"}' '.model_id=="claude-haiku-5-5" and (.deterministic|not)'
done
for p in amendment draft_approved_vision; do
  chk "phase $p = sonnet medium" 0 "$D"',"decision_class":"'$p'"}' '.model_id=="claude-sonnet-5-5" and .effort=="medium"'
done
for p in new_vision prioritization difficult_decomposition; do
  chk "phase $p = fable high (evidence)" 0 "$D"',"decision_class":"'$p'","evidence_refs":'"$EV"'}' '.model_id=="claude-fable-5-1" and .effort=="high"'
  chk "phase $p without evidence denied" 2 "$D"',"decision_class":"'$p'"}'
done
chk "consequential uncertainty = fable xhigh (evidence)" 0 "$D"',"decision_class":"consequential_uncertainty","evidence_refs":'"$EV"'}' '.model_id=="claude-fable-5-1" and .effort=="xhigh"'
chk "consequential uncertainty without evidence denied" 2 "$D"',"decision_class":"consequential_uncertainty"}'
chk "max without exception record denied" 2 "$D"',"decision_class":"max_exception"}'
chk "max with placeholder evidence denied" 2 "$D"',"decision_class":"max_exception","exception":{"reason":"unresolved_gap","evidence":["ledger:tbd"]}}'
chk "max exception with ledger evidence allowed" 0 "$D"',"decision_class":"max_exception","exception":{"reason":"unresolved_gap","evidence":["ledger:A1301"]}}' '.effort=="max" and .model_id=="claude-fable-5-1" and .exception==true'
chk "max exception with only file evidence denied (ledger record first)" 2 "$D"',"decision_class":"max_exception","exception":{"reason":"unresolved_gap","evidence":["file:'"$T"'/ev.md"]}}'
chk "max via requested override denied" 2 "$D"',"decision_class":"new_vision","evidence_refs":'"$EV"',"requested":{"model":"claude-fable-5-1","effort":"max"}}'
chk "requested model mismatch on haiku phase denied" 2 "$D"',"decision_class":"extraction","requested":{"model":"claude-fable-5-1"}}'
# regression: 5whysandrhyme/wwhtbt still reject max
chk "5whys max still forbidden" 2 '{"task_id":"A1301","skill":"5whysandrhyme","requested":{"effort":"max"}}'
# no inherited model for nested skills: a nested wwhtbt resolves from its own policy, not dream's
chk "nested wwhtbt keeps own baseline" 0 '{"task_id":"A1301","skill":"wwhtbt","parent_skill":"dream"}' '.model_id=="claude-sonnet-5-5" and .effort=="medium"'
# SKILL.md pin removal (set DREAM_SKILL to a SKILL.md; installed copy is merged separately)
if [ -n "${DREAM_SKILL:-}" ]; then
  fm=$(awk 'NR==1&&/^---$/{f=1;next} f&&/^---$/{exit} f' "$DREAM_SKILL")
  printf '%s\n' "$fm" | grep -Eq '^(model|effort):' && { echo "FAIL dream frontmatter has no blanket model/effort pin"; fail=1; } || echo "PASS dream frontmatter has no blanket model/effort pin"
  grep -Eqi 'Fable at max effort, pinned|use /dream Fable Max' "$DREAM_SKILL" && { echo "FAIL dream body has no blanket max pin"; fail=1; } || echo "PASS dream body has no blanket max pin"
  grep -q 'skill-routing/policy.json' "$DREAM_SKILL" && echo "PASS dream body points at the routing policy" || { echo "FAIL dream body points at the routing policy"; fail=1; }
else echo "SKIP dream SKILL.md pin checks (DREAM_SKILL unset)"; fi
exit $fail
