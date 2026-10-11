#!/usr/bin/env bash
# PRD dotfiles-config-edit-reload-check AC5: two edits 5 s apart leave exactly
# one waiter alive (`pgrep -f config-reload-check` count 1) and the notice
# reflects the second diff.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/crchk_test_helpers.sh"
crchk_setup
export CRCHK_POLL=1
edit_payload | run_hook >/dev/null
sleep 5
sed -i 's/^max_runs 3 → 4/max_runs 4 → 5/' "$FAKE_EFFECTIVE"
edit_payload | run_hook >/dev/null
sleep 0.5
assert_eq "$(pgrep -fc "config-reload-check.sh --wait $work")" "1" "exactly one waiter alive"
printf '{"op":"config-reloaded","row":{"key":"max_runs","new":5,"old":4},"table":"daemon","ts":"%s"}\n' "$(now_iso)" >>"$WM_BUILD_JOURNAL"
printf '{"op":"tick","row":{"admitted":[],"skipped":[],"config_loaded_at":"%s"},"table":"daemon","ts":"%s"}\n' "$(now_iso)" "$(now_iso)" >>"$WM_BUILD_JOURNAL"
f=$(wait_notice 30); assert_eq "$?" "0" "one notice appears"
assert_contains "$(cat "$f" 2>/dev/null)" "max_runs loaded 4→5" "notice reflects the second diff"
assert_eq "$(ls "$OPERATOR_CACHE_DIR"/notices | wc -l)" "1" "only one notice written"
exit $fail
