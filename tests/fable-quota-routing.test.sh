#!/usr/bin/env bash
# fable-quota-routing.test.sh (A1300, fable-quota-routing addendum 2026-11-08): the installed-shape contract, read back from source.
# Fresh Fable defaults to HIGH through the shared launcher, the skill recipes, the spawn gate, the native guard; xhigh/max are
# reasoned exceptions only. Runs the real launcher against a spy claude (no provider call). Run alone: bash tests/fable-quota-routing.test.sh
# FQR_ROOT=<tree> reruns the same assertions against another checkout (used to show RED on the pre-change bytes).
set -u
R="${FQR_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
L="$R/.local/bin/fable-launch.sh"; GATE="$R/.claude/hooks/fable-skill-spawn-gate.sh"; NG="$R/.claude/hooks/fable-native-agent-guard.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export ACCOUNT_LANE_STATE="$T/lanes" ACCOUNT_LANE_POLICY="${ACCOUNT_LANE_POLICY:-$R/tests/fixtures/account-lanes/policy.test.json}" ACCOUNT_LANE_TEST=1 ACCOUNT_LANE_NOW=1800000000
p=0; f=0; ck(){ if eval "$2"; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1"; fi; }
mkdir -p "$T/store"; printf 'TOKEN-PM-yyyyyyyy' >"$T/store/jyen.pm"; printf 'TOKEN-JOSEPH-xxxxxxxx' >"$T/store/josephsyen"; printf 'TOKEN-TECH-zzzzzzzz' >"$T/store/jyen.tech"; chmod 600 "$T/store"/*
printf '#!/usr/bin/env bash\necho "spy args=$*" >>"$SPYLOG"\n' >"$T/claude"; chmod +x "$T/claude"
export FABLE_LAUNCH_TEST=1 FABLE_TOKEN_STORE="$T/store" FABLE_CLAUDE_BIN="$T/claude" SPYLOG="$T/spy.log" FABLE_RR_DIR="$T/rr" SKILL_ROUTING_DECISIONS="$T/dec.jsonl"
unset FABLE_LAUNCH_EFFORT_REASON
run(){ : >"$SPYLOG"; "$L" "$@" 2>"$T/err"; echo $? >"$T/rc"; }
rc(){ cat "$T/rc"; }
# --- 1. launcher contract
run --model claude-fable-5-1 --effort high -p x;   ck "launcher: explicit Fable high accepted" '[ "$(rc)" = 0 ] && grep -q -- "--effort high" "$SPYLOG"'
run --model claude-fable-5-1 -p x;                 ck "launcher: omitted effort defaults to high" '[ "$(rc)" = 0 ] && grep -q -- "--effort high" "$SPYLOG" && ! grep -q xhigh "$SPYLOG"'
run --model claude-fable-5-1 --effort xhigh -p x;  ck "launcher: xhigh without a reason refused" '[ "$(rc)" = 64 ] && [ ! -s "$SPYLOG" ] && grep -q FABLE_LAUNCH_EFFORT_REASON "$T/err"'
run --model claude-fable-5-1 --effort max -p x;    ck "launcher: max without a reason refused (clean 64, no crash)" '[ "$(rc)" = 64 ] && [ ! -s "$SPYLOG" ]'
FABLE_LAUNCH_EFFORT_REASON="short" run --model claude-fable-5-1 --effort xhigh -p x; ck "launcher: too-short reason refused" '[ "$(rc)" = 64 ] && [ ! -s "$SPYLOG" ]'
FABLE_LAUNCH_EFFORT_REASON="ledger:A1300 named gap" run --model claude-fable-5-1 --effort xhigh -p x; ck "launcher: xhigh with a recorded reason accepted and the reason echoed" '[ "$(rc)" = 0 ] && grep -q -- "--effort xhigh" "$SPYLOG" && grep -q "ledger:A1300 named gap" "$T/err"'
FABLE_LAUNCH_EFFORT_REASON="ledger:A1300 named gap" run --model claude-fable-5-1 --effort max -p x; ck "launcher: max with a recorded reason accepted" '[ "$(rc)" = 0 ] && grep -q -- "--effort max" "$SPYLOG"'
unset FABLE_LAUNCH_EFFORT_REASON
run --model claude-fable-5-1 --effort turbo -p x;  ck "launcher: unknown effort refused" '[ "$(rc)" = 64 ] && [ ! -s "$SPYLOG" ]'
run --model claude-fable-5-1 --effort high --effort high -p x; ck "launcher: duplicate --effort still refused" '[ "$(rc)" = 64 ]'
run --model claude-sonnet-5-5 --effort medium -p x; ck "launcher: non-Fable stays on josephsyen, effort untouched" '[ "$(rc)" = 0 ] && grep -q -- "--effort medium" "$SPYLOG" && ! grep -q TOKEN- "$SPYLOG"'
# --- 2. skill sources: pins and recipes read back
for sk in 5whysandrhyme wwhtbt; do
  sf="$R/.claude/skills/$sk/SKILL.md"
  fm=$(awk 'NR==1&&$0!="---"{exit} NR==1{next} $0=="---"{exit} {print}' "$sf")
  ck "$sk: frontmatter effort high" 'grep -qx "effort: high" <<<"$fm"'
  ck "$sk: body no longer declares xhigh the default" '! grep -q "approved xhigh as the default" "$sf" && ! grep -q "Pins: .*effort: xhigh" "$sf"'
  ck "$sk: xhigh/max documented as reasoned exception with the reason recorded first" 'grep -q "FABLE_LAUNCH_EFFORT_REASON" "$sf" && grep -qi "exception" "$sf"'
  ck "$sk: still no unconditional second review" 'grep -q "default: no second Fable launch" "$sf" && grep -q "review_reason:" "$sf"'
  # execute the recipe the skill tells a caller to run, against the real launcher
  cmd=$(grep -o 'fable-launch.sh --model claude-fable-5-1 --effort [a-z]* -p' "$sf" | head -1)
  ck "$sk: recipe launches at high" '[ -n "$cmd" ] && grep -q -- "--effort high" <<<"$cmd"'
  # shellcheck disable=SC2086
  run ${cmd#fable-launch.sh } x; ck "$sk: recipe executes on the real launcher (rc 0, high)" '[ "$(rc)" = 0 ] && grep -q -- "--effort high" "$SPYLOG"'
done
# --- 3. spawn gate: recipe effort follows the skill pin; default high when unpinned
mkdir -p "$T/skills/wwhtbt" "$T/skills/nopin"
cp "$R/.claude/skills/wwhtbt/SKILL.md" "$T/skills/wwhtbt/SKILL.md"
printf -- '---\nname: nopin\nmodel: fable\nfable-spawn: true\n---\nbody\n' >"$T/skills/nopin/SKILL.md"
printf '{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tu1"}]}}\n' >"$T/t.jsonl"
gate(){ printf '{"tool_name":"Skill","tool_input":{"skill":"%s","args":"plan X"},"transcript_path":"%s","tool_use_id":"tu1","session_id":"s1"}' "$1" "$T/t.jsonl" | FABLE_SKILLS_DIR="$T/skills" SKILL_MARKER_DIR="$T/marks" "$GATE" 2>&1 >/dev/null; }
g=$(gate wwhtbt); ck "gate: governed skill recipe is the managed route, never a pinned xhigh" 'grep -q -- "--route-request" <<<"$g" && ! grep -q xhigh <<<"$g"'
# the managed route the recipe points at, end to end on the real launcher + repo policy: baseline high, cheap routine, reasoned xhigh only
export SKILL_ROUTE_POLICY="$R/.config/skill-routing/policy.json" SKILL_ROUTE_LEDGER_IDS="$T/ids.txt"; printf 'A1300\n' >"$T/ids.txt"; echo e >"$T/ev.md"
EVJ='["ledger:A1300","file:'"$T"'/ev.md"]'
rr(){ printf '%s' "$1" >"$T/req.json"; : >"$SPYLOG"; "$L" --route-request "$T/req.json" -p x 2>"$T/err"; echo $? >"$T/rc"; }
rr '{"task_id":"Q1","skill":"5whysandrhyme"}'; ck "route: 5whys default = fable high, no second launch row" 'grep -q -- "--effort high" "$SPYLOG" && [ "$(grep -c . "$SPYLOG")" = 1 ]'
rr '{"task_id":"Q2","skill":"wwhtbt"}'; ck "route: routine wwhtbt = sonnet medium (cheaper routine path)" 'grep -q -- "--model claude-sonnet-5-5" "$SPYLOG" && grep -q -- "--effort medium" "$SPYLOG"'
rr '{"task_id":"Q3","skill":"wwhtbt","decision_class":"strategy_cross_system","evidence_refs":'"$EVJ"'}'; ck "route: cross-system wwhtbt = fable high" 'grep -q -- "--model claude-fable-5-1" "$SPYLOG" && grep -q -- "--effort high" "$SPYLOG"'
rr '{"task_id":"Q4","skill":"5whysandrhyme","escalation":{"reason":"recurring_failure","evidence":'"$EVJ"'}}'; ck "route: evidenced recurring failure = xhigh exception" 'grep -q -- "--effort xhigh" "$SPYLOG"'
rr '{"task_id":"Q5","skill":"5whysandrhyme","escalation":{"reason":"recurring_failure","evidence":["none"]}}'; ck "route: xhigh without real evidence denied, nothing started" '[ "$(rc)" = 64 ] && [ ! -s "$SPYLOG" ]'
g=$(gate nopin); ck "gate: skill with no effort pin defaults to high" 'grep -q -- "--effort high" <<<"$g"'
# --- 4. native guard: Fable high allowed under jyen.pm; xhigh must go through the launcher with a reason
ng(){ printf '{"tool_name":"Agent","tool_input":{"model":"claude-fable-5-1","effort":"%s","prompt":"x"}}' "$1" | FABLE_LAUNCH_ACCOUNT=jyen.pm "$NG"; }
ck "native guard: fable high allowed" '[ -z "$(ng high)" ]'
o=$(ng xhigh); ck "native guard: fable xhigh denied with the reason route named" 'grep -q "\"permissionDecision\":\"deny\"" <<<"$o" && grep -q FABLE_LAUNCH_EFFORT_REASON <<<"$o"'
echo "pass=$p fail=$f"; [ $f = 0 ] && echo ALL PASS; exit $f
