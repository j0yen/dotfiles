#!/usr/bin/env bash
# dpms AC 1 (+ R4 cases, R5(a) and R5(b) controls): with a fresh legacy
# ~/.claude/.dream-active, session T's PRD Write is denied whatever the
# marker directory holds (absent, empty, stale-only, another session's fresh
# markers, a fresh sibling dream.<T>); the 61d0c6a2 gate admits every one of
# those cases, and a conditional legacy-fallback mutant admits the empty and
# stale-only cases, so the suite tells the landed gate from both.
. "$(dirname "$0")/dpms_test_helpers.sh"
fixture_check

T_IN() { write_input T "$PRD"; }

# (a) marker directory absent
dpms_setup; fresh_legacy
expect_deny "$GATE" "$(T_IN)" marker-absent "AC1(a) dir absent"
[ -e "$SKILL_MARKER_DIR" ] && notok "AC1(a) gate created no marker directory" || ok "AC1(a) gate created no marker directory"
run_gate "$FIX_GATE" "$(T_IN)"; [ "$RC" = 0 ] && [ -z "$OUT" ] && ok "R5(a) fixture admits dir-absent" || notok "R5(a) fixture admits dir-absent (out=$OUT)"
mutant_fallback "$work/fallback.sh"
cmp -s "$GATE" "$work/fallback.sh" && notok "R5(b) fallback edit changed the gate" || ok "R5(b) fallback edit changed the gate"
grep -q '_dpms_landed_dream_active' "$work/fallback.sh" && ok "R5(b) fallback wrapper installed" || notok "R5(b) fallback wrapper installed"

# (a) marker directory empty
dpms_setup; fresh_legacy; mkdir -p "$SKILL_MARKER_DIR"
expect_deny "$GATE" "$(T_IN)" marker-absent "AC1(a) dir empty"
[ -e "$SKILL_MARKER_DIR/dream-prd.T" ] && notok "AC1(a) empty: no dream-prd.T created" || ok "AC1(a) empty: no dream-prd.T created"
run_gate "$FIX_GATE" "$(T_IN)"; [ "$RC" = 0 ] && [ -z "$OUT" ] && ok "R5(a) fixture admits dir-empty" || notok "R5(a) fixture admits dir-empty (out=$OUT)"
mutant_fallback "$work/fallback.sh"
run_gate "$work/fallback.sh" "$(T_IN)"; [ "$RC" = 0 ] && [ -z "$OUT" ] && ok "R5(b) fallback mutant admits dir-empty" || notok "R5(b) fallback mutant admits dir-empty (out=$OUT)"

# (b) only stale dream-prd.T and dream-prd.S
dpms_setup; fresh_legacy; mk_marker dream-prd.T 181; mk_marker dream-prd.S 181
expect_deny "$GATE" "$(T_IN)" marker-stale "AC1(b) stale-only"
run_gate "$FIX_GATE" "$(T_IN)"; [ "$RC" = 0 ] && [ -z "$OUT" ] && ok "R5(a) fixture admits stale-only" || notok "R5(a) fixture admits stale-only (out=$OUT)"
mutant_fallback "$work/fallback.sh"
run_gate "$work/fallback.sh" "$(T_IN)"; [ "$RC" = 0 ] && [ -z "$OUT" ] && ok "R5(b) fallback mutant admits stale-only" || notok "R5(b) fallback mutant admits stale-only (out=$OUT)"

# (c) another session's fresh dream-prd.S and dream.S
dpms_setup; fresh_legacy; mk_marker dream-prd.S 1; mk_marker dream.S 1
expect_deny "$GATE" "$(T_IN)" marker-absent "AC1(c) foreign fresh"
[ -e "$SKILL_MARKER_DIR/dream-prd.T" ] && notok "AC1(c) no dream-prd.T created" || ok "AC1(c) no dream-prd.T created"
run_gate "$FIX_GATE" "$(T_IN)"; [ "$RC" = 0 ] && [ -z "$OUT" ] && ok "R5(a) fixture admits foreign-fresh" || notok "R5(a) fixture admits foreign-fresh (out=$OUT)"

# R4: a fresh sibling dream.<T> (spawn gate / skill-marker file) is not a stand-in
dpms_setup; fresh_legacy; mk_marker dream.T 1
expect_deny "$GATE" "$(T_IN)" marker-absent "R4 dream.T only"
[ "$(mtime "$SKILL_MARKER_DIR/dream.T")" != none ] && ok "R4 dream.T left in place" || notok "R4 dream.T left in place"

# Edge: an unreadable marker directory is no marker (skipped as root)
if [ "$(id -u)" != 0 ]; then
  dpms_setup; fresh_legacy; mk_marker dream-prd.T 1; chmod 000 "$SKILL_MARKER_DIR"
  run_gate "$GATE" "$(T_IN)"
  is_deny "$OUT" && ok "edge unreadable dir: denied" || notok "edge unreadable dir: denied (out=$OUT)"
  assert_contains "$(log_last)" "reason=marker-absent" "edge unreadable dir: logged marker-absent"
  chmod 700 "$SKILL_MARKER_DIR"
else echo "# skip unreadable-dir case as root"; fi

finish
