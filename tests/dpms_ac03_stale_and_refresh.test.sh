#!/usr/bin/env bash
# dpms AC 3 (+ R5(d) control): a stale own marker denies marker-stale twice
# and is left untouched; an admit by a 170-min own marker refreshes only that
# marker. A deny-refresh mutant (touch between reading the mtime and the
# comparison) denies the first input and admits the second, which the
# unchanged-mtime and second-input assertions catch.
. "$(dirname "$0")/dpms_test_helpers.sh"

S_IN() { write_input S "$PRD"; }

dpms_setup; fresh_legacy; mk_marker dream-prd.S 181
before=$(mtime "$SKILL_MARKER_DIR/dream-prd.S")
expect_deny "$GATE" "$(S_IN)" marker-stale "AC3 stale own marker"
assert_eq "$(mtime "$SKILL_MARKER_DIR/dream-prd.S")" "$before" "AC3 S marker mtime unchanged after two denies"
assert_eq "$(grep -c 'reason=marker-stale' "$LOG")" 2 "AC3 two marker-stale log lines"
assert_contains "$(log_last)" "session=S" "AC3 log names session=S"

dpms_setup; mk_marker dream-prd.S 170; mk_marker dream-prd.T 60
t_before=$(mtime "$SKILL_MARKER_DIR/dream-prd.T")
expect_pass "$GATE" "$(S_IN)" "AC3 170-min own marker admits"
fresh_within "$SKILL_MARKER_DIR/dream-prd.S" 2 && ok "AC3 S marker refreshed to now" || notok "AC3 S marker refreshed to now"
assert_eq "$(mtime "$SKILL_MARKER_DIR/dream-prd.T")" "$t_before" "AC3 T marker mtime unchanged"

# R5(d) deny-refresh mutant
dpms_setup; fresh_legacy; mk_marker dream-prd.S 181
mutant_deny_refresh "$work/denyrefresh.sh"
cmp -s "$GATE" "$work/denyrefresh.sh" && notok "R5(d) edit changed the gate" || ok "R5(d) edit changed the gate"
run_gate "$work/denyrefresh.sh" "$(S_IN)"
is_deny "$OUT" && ok "R5(d) mutant denies the first input" || notok "R5(d) mutant denies the first input (out=$OUT)"
run_gate "$work/denyrefresh.sh" "$(S_IN)"
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok "R5(d) mutant admits the second identical input" || notok "R5(d) mutant admits the second identical input (out=$OUT)"
finish
