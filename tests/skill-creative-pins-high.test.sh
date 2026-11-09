#!/usr/bin/env bash
# skill-creative-pins-high.test.sh (A1300 slice C, fable-quota-routing addendum 2026-11-08 §1): /write, /improv, /beauty pin
# Fable HIGH as the baseline; xhigh/max pins are gone from the tracked frontmatter. Reads the tracked SKILL.md frontmatter
# only; exceptions go through fable-launch.sh with FABLE_LAUNCH_EFFORT_REASON, never a pin. Run alone: bash tests/skill-creative-pins-high.test.sh
set -u
R="${SCP_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
p=0; f=0; ck(){ if eval "$2"; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1"; fi; }
for sk in write improv beauty; do
  sf="$R/.claude/skills/$sk/SKILL.md"
  fm=$(awk 'NR==1&&$0!="---"{exit} NR==1{next} $0=="---"{exit} {print}' "$sf" 2>/dev/null)
  ck "$sk: tracked SKILL.md present" '[ -r "$sf" ]'
  ck "$sk: model fable pinned" 'grep -qx "model: fable" <<<"$fm"'
  ck "$sk: effort high baseline" 'grep -qx "effort: high" <<<"$fm"'
  ck "$sk: no xhigh/max pin in frontmatter" '! grep -qE "^effort:[[:space:]]*(xhigh|max)" <<<"$fm"'
  ck "$sk: single effort key" '[ "$(grep -c "^effort:" <<<"$fm")" = 1 ]'
  ck "$sk: not gated into an xhigh spawn recipe (no fable-spawn key)" '! grep -q "^fable-spawn:" <<<"$fm"'
done
echo "pass=$p fail=$f"; [ $f = 0 ] && echo ALL PASS; exit $f
