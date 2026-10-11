#!/usr/bin/env bash
# PRD dotfiles-config-edit-reload-check AC7: with 2 admitted and 3 skipped in
# the tick row, the notice's last line is
# `admission: 2 admitted / 3 skipped in that tick`.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/crchk_test_helpers.sh"
crchk_setup
edit_payload | run_hook >/dev/null
( sleep 1; append_tick 2 3 ) &
f=$(wait_notice 30); assert_eq "$?" "0" "notice appears"
assert_eq "$(tail -n 1 "$f")" "admission: 2 admitted / 3 skipped in that tick" "last line is the admission count"
wait
exit $fail
