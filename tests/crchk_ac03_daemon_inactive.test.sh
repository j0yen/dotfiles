#!/usr/bin/env bash
# PRD dotfiles-config-edit-reload-check AC3: with systemctl reporting inactive,
# an edit of config.toml prints exactly one line and spawns no waiter.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/crchk_test_helpers.sh"
crchk_setup
export FAKE_ACTIVE=inactive
out=$(edit_payload | run_hook); rc=$?
assert_eq "$rc" "0" "exit 0"
assert_eq "$out" "daemon inactive; file saved, nothing to confirm" "exactly the one inactive line"
sleep 0.5
assert_eq "$(pgrep -fc "config-reload-check.sh --wait $work")" "0" "no waiter process"
assert_eq "$(ls "$OPERATOR_CACHE_DIR")" "" "no state or notice written"
exit $fail
