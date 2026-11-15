#!/usr/bin/env bash
# dpms AC 5: with only S's fresh marker and a fresh legacy file, every Bash
# creation form the gate matches at 61d0c6a2 line 60 (>, >>, tee, tee -a, cp,
# install) from session T is denied; the same forms from S are admitted; an
# Edit of a queued PRD is never gated. Each form is first shown to be one the
# 61d0c6a2 regex matches (the pinned fixture denies it with no marker at all).
# At 61d0c6a2 a cp/install is matched only when its first operand after the
# options contains the build-queue path; that regex is unchanged here.
. "$(dirname "$0")/dpms_test_helpers.sh"

# @P@ = the PRD path, @O@ = another queued PRD path (filled per temp HOME)
forms() {
  printf '%s\n' "echo x > @P@" "echo x >> @P@" "echo x | tee @P@" "echo x | tee -a @P@" \
    "cp @O@ @P@" "install -D @O@ @P@"
}
while IFS= read -r tmpl; do
  dpms_setup
  cmd=${tmpl//@P@/$PRD}; cmd=${cmd//@O@/${PRD%x.md}old.md}
  run_gate "$FIX_GATE" "$(bash_input T "$cmd")"; is_deny "$OUT" && ok "AC5 form matched at 61d0c6a2: $cmd" || notok "AC5 form matched at 61d0c6a2: $cmd"
  dpms_setup; fresh_legacy; mk_marker dream-prd.S 1
  cmd=${tmpl//@P@/$PRD}; cmd=${cmd//@O@/${PRD%x.md}old.md}
  expect_deny "$GATE" "$(bash_input T "$cmd")" marker-absent "AC5 T: $tmpl"
  [ -e "$SKILL_MARKER_DIR/dream-prd.T" ] && notok "AC5 no dream-prd.T created" || ok "AC5 no dream-prd.T created"
  run_gate "$FIX_GATE" "$(bash_input T "$cmd")"; [ -z "$OUT" ] && ok "AC5 control: fixture admits T" || notok "AC5 control: fixture admits T (out=$OUT)"
  expect_pass "$GATE" "$(bash_input S "$cmd")" "AC5 S own marker admits the same form"
done < <(forms)

dpms_setup; fresh_legacy; mk_marker dream-prd.S 1
expect_pass "$GATE" "$(edit_input T "$PRD")" "AC5 Edit of a queued PRD from T ungated"
dpms_setup
expect_pass "$GATE" "$(edit_input T "$PRD")" "AC5 Edit with no marker at all ungated"
# git mv / sed -i on an existing queued PRD pass through, as at 61d0c6a2
dpms_setup
expect_pass "$GATE" "$(bash_input T "sed -i s/a/b/ $PRD")" "AC5 sed -i on a queued PRD ungated"
finish
