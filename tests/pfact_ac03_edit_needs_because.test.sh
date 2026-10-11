#!/usr/bin/env bash
# PRD dotfiles-park-requires-fresh-fact AC3: an Edit setting `- Status: blocked` with
# no because: is refused; with because: decision=165 and no commit on the slug
# in 60 min it passes.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/pfact_test_helpers.sh"
pfact_setup

sqlite3 "$WM_STATE_DB" "insert into decisions(id,question,opened) values (165,'q','$(iso_ago 300)')"
path="$PRD_DIR/build-queue/PRD-x.md"

run_hook "$(edit_payload Edit "$path" '- Status: blocked')"
assert_eq "$rc" "2" "no because: is refused"
assert_contains "$out" "PARK NEEDS because:" "stdout carries the PARK NEEDS because: line"

run_hook "$(edit_payload Edit "$path" '- Status: blocked
- Note: stuck # because: decision=165')"
assert_eq "$rc" "0" "decision=165 with no recent commit on x passes"
assert_eq "$out" "" "no stdout on pass"
exit $fail
