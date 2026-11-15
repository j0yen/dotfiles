#!/usr/bin/env bash
# dpms AC 4: the ~/.claude/.allow-prd-handfile override admits as before,
# creates no marker and refreshes none (no marker, 170-min and 181-min own
# marker), whatever the session.
. "$(dirname "$0")/dpms_test_helpers.sh"

for age in none 170 181; do
  dpms_setup; touch "$HOME/.claude/.allow-prd-handfile"; mkdir -p "$SKILL_MARKER_DIR"
  [ "$age" = none ] || mk_marker dream-prd.U "$age"
  mk_marker dream-prd.V 30
  before=$(snap)
  expect_pass "$GATE" "$(write_input U "$PRD")" "AC4 override, own marker $age"
  assert_eq "$(snap)" "$before" "AC4 override, own marker $age: dream-prd.* names and mtimes unchanged"
  [ "$age" = none ] && { [ -e "$SKILL_MARKER_DIR/dream-prd.U" ] && notok "AC4 no dream-prd.U created" || ok "AC4 no dream-prd.U created"; }
done
# override also admits the Bash creation form unchanged
dpms_setup; touch "$HOME/.claude/.allow-prd-handfile"
expect_pass "$GATE" "$(bash_input U "echo x > $PRD")" "AC4 override admits a Bash redirect"
assert_eq "$(snap)" "dir=absent" "AC4 override created no marker directory"
finish
