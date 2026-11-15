#!/usr/bin/env bash
# dpms AC 6 (+ R1, R5(c) control): dream-marker.sh creates the absent marker
# directory and a fresh dream-prd.<S> for a Skill(dream) call and a typed
# /dream, never writes ~/.claude/.dream-active, writes nothing for an empty or
# missing session id or a non-dream skill/prompt; the pinned 61d0c6a2 hook
# under the same inputs writes .dream-active inside the temporary HOME and no
# dream-prd.*, which proves both the isolation and the negative assertion.
. "$(dirname "$0")/dpms_test_helpers.sh"
fixture_check

skill_in() { jq -cn --arg s "$1" --arg k "$2" '{session_id:$s,hook_event_name:"PreToolUse",tool_name:"Skill",tool_input:{skill:$k}}'; }
prompt_in() { jq -cn --arg s "$1" --arg p "$2" '{session_id:$s,hook_event_name:"UserPromptSubmit",prompt:$p}'; }
real_legacy_before=$(mtime "$REAL_HOME/.claude/.dream-active")

for case in "skill:dream" "skill:vibecode-kit:dream" "prompt:/dream seed text" "prompt:  /dream"; do
  kind=${case%%:*}; val=${case#*:}
  dpms_setup  # HOME holds .claude/, SKILL_MARKER_DIR names a path that does not exist
  [ -e "$SKILL_MARKER_DIR" ] && notok "AC6 precondition: marker dir absent" || true
  if [ "$kind" = skill ]; then in=$(skill_in S "$val"); else in=$(prompt_in S "$val"); fi
  printf '%s' "$in" | bash "$MARKER_HOOK"; rc=$?
  assert_eq "$rc" 0 "AC6 $case: exit 0"
  [ -d "$SKILL_MARKER_DIR" ] && ok "AC6 $case: marker dir created" || notok "AC6 $case: marker dir created"
  fresh_within "$SKILL_MARKER_DIR/dream-prd.S" 2 && ok "AC6 $case: dream-prd.S fresh" || notok "AC6 $case: dream-prd.S fresh"
  [ -e "$HOME/.claude/.dream-active" ] && notok "AC6 $case: .dream-active absent" || ok "AC6 $case: .dream-active absent"
  # the marker the hook wrote admits that session's PRD write through the gate
  expect_pass "$GATE" "$(write_input S "$PRD")" "AC6 $case: S then admitted by the gate"
  # R5(c): the 61d0c6a2 hook, same input, same HOME layout
  dpms_setup
  printf '%s' "$in" | bash "$FIX_MARKER"
  [ -e "$HOME/.claude/.dream-active" ] && ok "R5(c) $case: old hook wrote .dream-active in the temp HOME" || notok "R5(c) $case: old hook wrote .dream-active in the temp HOME"
  assert_eq "$(find "$work" -name 'dream-prd.*' | wc -l)" 0 "R5(c) $case: old hook wrote no dream-prd.*"
done
assert_eq "$(mtime "$REAL_HOME/.claude/.dream-active")" "$real_legacy_before" "R5(c) real HOME .dream-active untouched by every run"

# empty / missing session id, non-dream skills and prompts: nothing written
for in in "$(skill_in "" dream)" "$(prompt_in "" "/dream x")" \
          "$(jq -cn '{tool_name:"Skill",tool_input:{skill:"dream"}}')" \
          "$(skill_in S dreamcatcher)" "$(skill_in S foo:dreamcatcher)" "$(skill_in S write)" \
          "$(prompt_in S "/dreamer x")" "$(prompt_in S "please /dream")" "not json"; do
  dpms_setup
  printf '%s' "$in" | bash "$MARKER_HOOK"; rc=$?
  assert_eq "$rc" 0 "AC6 no-write input exits 0: ${in:0:60}"
  assert_eq "$(find "$HOME" \( -name 'dream-prd.*' -o -name '.dream-active' -o -name '*nosession*' \) | wc -l)" 0 "AC6 nothing written: ${in:0:60}"
  [ -e "$SKILL_MARKER_DIR" ] && notok "AC6 no marker dir created: ${in:0:60}" || ok "AC6 no marker dir created: ${in:0:60}"
done
finish
