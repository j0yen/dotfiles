#!/usr/bin/env bash
# dpms AC 2 (+ R4 non-matching path): session S's own fresh dream-prd.<S>
# admits its PRD Write (exit 0, no decision) and the gate refreshes that
# marker; a Write to a non-PRD path is ungated in any marker state.
. "$(dirname "$0")/dpms_test_helpers.sh"

dpms_setup; mk_marker dream-prd.S 30
expect_pass "$GATE" "$(write_input S "$PRD")" "AC2 own fresh marker admits"
fresh_within "$SKILL_MARKER_DIR/dream-prd.S" 2 && ok "AC2 dream-prd.S mtime within 2 s of now" || notok "AC2 dream-prd.S mtime within 2 s of now ($(mtime "$SKILL_MARKER_DIR/dream-prd.S"))"
assert_eq "$(cat "$LOG" 2>/dev/null)" "" "AC2 an admit leaves no log line"

# Within the TTL boundary: 179 min still admits; DREAM_TTL_MIN stays the seam
dpms_setup; mk_marker dream-prd.S 179
expect_pass "$GATE" "$(write_input S "$PRD")" "AC2 179-min marker admits (TTL 180)"
dpms_setup; mk_marker dream-prd.S 30
OUT=$(write_input S "$PRD" | DREAM_TTL_MIN=10 bash "$GATE"); is_deny "$OUT" && ok "AC2 DREAM_TTL_MIN=10 makes a 30-min marker stale" || notok "AC2 DREAM_TTL_MIN seam (out=$OUT)"

# R4: non-matching paths from a markerless session — ungated
for p in "$work/proj/PRDs/notes/PRD-x.md" "$work/proj/build-queue/README.md" "$work/proj/build-queue/prd-x.md"; do
  dpms_setup
  expect_pass "$GATE" "$(write_input T "$p")" "R4 non-matching path ${p#$work/} ungated"
  assert_eq "$(snap)" "dir=absent" "R4 non-matching path: no marker directory created"
done
finish
