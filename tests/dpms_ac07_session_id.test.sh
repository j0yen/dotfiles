#!/usr/bin/env bash
# dpms AC 7: a Write with no (or an empty) session_id is denied
# reason=no-session-id and creates no marker; malformed JSON exits 0 with no
# decision; a subagent-shaped input with its own session id U is denied twice
# and creates no dream-prd.<U>.
. "$(dirname "$0")/dpms_test_helpers.sh"

dpms_setup; fresh_legacy; mk_marker dream-prd.S 1
expect_deny "$GATE" "$(write_input - "$PRD")" no-session-id "AC7 no session_id field"
assert_contains "$(log_last)" "session=missing" "AC7 log session=missing"
assert_eq "$(find "$SKILL_MARKER_DIR" -name 'dream-prd.*' | wc -l)" 1 "AC7 no dream-prd.* created (only S's)"
expect_deny "$GATE" "$(write_input "" "$PRD")" no-session-id "AC7 empty session_id"
expect_deny "$GATE" "$(jq -cn --arg p "$PRD" '{session_id:null,tool_name:"Write",tool_input:{file_path:$p}}')" no-session-id "AC7 null session_id"
run_gate "$FIX_GATE" "$(write_input - "$PRD")"; [ -z "$OUT" ] && ok "AC7 control: fixture admits an id-less input" || notok "AC7 control: fixture admits an id-less input"

dpms_setup; fresh_legacy; mk_marker dream-prd.S 1
for bad in '{"tool_name":"Write","tool_input":' 'not json at all' '{"session_id":"S","tool_name":'; do
  expect_pass "$GATE" "$bad" "AC7 malformed JSON fails open: ${bad:0:30}"
done
expect_pass "$GATE" "" "AC7 empty input fails open"

dpms_setup; fresh_legacy; mk_marker dream-prd.S 1
expect_deny "$GATE" "$(write_input U "$PRD")" marker-absent "AC7 subagent-shaped U"
[ -e "$SKILL_MARKER_DIR/dream-prd.U" ] && notok "AC7 no dream-prd.U exists" || ok "AC7 no dream-prd.U exists"
run_gate "$FIX_GATE" "$(write_input U "$PRD")"; [ -z "$OUT" ] && ok "AC7 control: fixture admits U" || notok "AC7 control: fixture admits U"

# R3 log line shape: deny lines only, with session= and reason=
assert_eq "$(grep -vc ' session=[^ ]* reason=\(marker-absent\|marker-stale\|no-session-id\)$' "$LOG")" 0 "R3 every log line ends session=<id> reason=<token>"
finish
