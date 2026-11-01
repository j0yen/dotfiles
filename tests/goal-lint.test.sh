#!/usr/bin/env bash
# goal-lint: every `/goal` line in goal.md carries the five stop-hook judging properties.
# Fixtures live in a mktemp dir; the real goal.md is never read.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
GL="$here/.local/bin/goal-lint.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok - $1"; }
no() { echo "NOT OK - $1"; fail=1; }

GOOD='/goal ALPHA: judge ONLY the final assistant message; STATUS block with read times; unmeasured pass; WAIT until <event>; never require X, forbid Y'

# (a) compliant -> exit 0, ok
printf '%s\n' "$GOOD" > "$T/a.md"
out="$(bash "$GL" "$T/a.md")"; rc=$?
{ [ $rc = 0 ] && [ "$out" = "goal-lint: ALPHA ok" ]; } && ok "compliant line exits 0 with ok" || no "compliant line: rc=$rc out=$out"

# (b) missing P3 and P4
l="${GOOD//unmeasured/pending}"; l="${l//WAIT until </WAIT for <}"
printf '%s\n' "$l" > "$T/b.md"
out="$(bash "$GL" "$T/b.md")"; rc=$?
{ [ $rc = 1 ] && [ "$out" = "goal-lint: ALPHA MISSING P3,P4" ]; } && ok "missing P3,P4 exits 1 and names them" || no "missing P3,P4: rc=$rc out=$out"

# (c) two goals, one ok, one missing P1
{ printf '%s\n' "$GOOD"; printf '%s\n' "${GOOD//ALPHA/BETA}" | sed 's/judge ONLY the final assistant message/judge things/'; } > "$T/c.md"
out="$(bash "$GL" "$T/c.md")"; rc=$?
{ [ $rc = 1 ] && printf '%s\n' "$out" | grep -qx 'goal-lint: ALPHA ok' && printf '%s\n' "$out" | grep -qx 'goal-lint: BETA MISSING P1'; } \
  && ok "two goals: both lines printed, exit 1" || no "two goals: rc=$rc out=$out"

# (d) missing file
bash "$GL" "$T/none.md" >/dev/null 2>&1; rc=$?
[ $rc = 2 ] && ok "missing file exits 2" || no "missing file: rc=$rc"

# (e) non-/goal line containing the words is ignored
printf 'note: judge ONLY the final assistant message, unmeasured, WAIT until <x>, never require, forbid\n' > "$T/e.md"
out="$(bash "$GL" "$T/e.md")"; rc=$?
{ [ $rc = 0 ] && [ -z "$out" ]; } && ok "non-/goal line ignored" || no "non-/goal line: rc=$rc out=$out"


# (f) dormant goal + ok goal -> exit 0
{ printf '%s\n' "${GOOD//ALPHA/AA}"; printf '%s\n' '- Dormant: headless seat'; printf '%s\n' "${GOOD//ALPHA/BB}"; } > "$T/f.md"
sed -i '1s/.*/\/goal AA: nothing/' "$T/f.md"
out="$(bash "$GL" "$T/f.md")"; rc=$?
{ [ $rc = 0 ] && printf '%s\n' "$out" | grep -qx 'goal-lint: AA dormant' && printf '%s\n' "$out" | grep -qx 'goal-lint: BB ok'; } \
  && ok "dormant + ok exits 0" || no "dormant + ok: rc=$rc out=$out"

# (g) parked goal missing everything + goal missing P1 -> exit 1
{ printf '%s\n' '/goal AA: nothing' '  - Parked until stage 2'; printf '%s\n' "${GOOD//ALPHA/BB}" | sed 's/judge ONLY the final assistant message/judge things/'; } > "$T/g.md"
out="$(bash "$GL" "$T/g.md")"; rc=$?
{ [ $rc = 1 ] && printf '%s\n' "$out" | grep -qx 'goal-lint: AA parked' && printf '%s\n' "$out" | grep -qx 'goal-lint: BB MISSING P1'; } \
  && ok "parked + MISSING P1 exits 1" || no "parked + missing: rc=$rc out=$out"

# (h) marker after a ## heading is outside the block
printf '%s\n' '/goal AA: nothing' '## Next section' '- Dormant thing' > "$T/h.md"
out="$(bash "$GL" "$T/h.md")"; rc=$?
{ [ $rc = 1 ] && [ "$out" = "goal-lint: AA MISSING P1,P2,P3,P4,P5" ]; } && ok "marker past ## heading ignored" || no "block boundary: rc=$rc out=$out"

# (i) bold form
printf '%s\n' '/goal AA: nothing' '- **Parked until later**' > "$T/i.md"
out="$(bash "$GL" "$T/i.md")"; rc=$?
{ [ $rc = 0 ] && [ "$out" = "goal-lint: AA parked" ]; } && ok "bold Parked marks goal" || no "bold parked: rc=$rc out=$out"

# selftest + help
bash "$GL" --selftest | grep -qx 'SELFTEST PASS 9/0' && ok "--selftest passes" || no "--selftest"
bash "$GL" --help | grep -q 'P5' && ok "--help lists properties" || no "--help"

[ $fail = 0 ] && echo "PASS goal-lint" || echo "FAIL goal-lint"
exit $fail
